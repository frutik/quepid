# frozen_string_literal: true

require 'test_helper'

module LlmJudgeAdapters
  class JevComparisonTest < ActiveSupport::TestCase
    let(:query) { query_doc_pairs(:starwars_qdp1) }
    let(:doc_a) { { 'title' => 'Han Solo' } }
    let(:doc_b) { { 'title' => 'The Movie' } }
    let(:adapter) { Jev.new('ts-key', { llm_provider: 'typesafe_jev' }) }

    def envelope swapped: false
      adapter.comparison_envelope(query, doc_a, doc_b, system_prompt: 'Judge relevance.', swapped: swapped)
    end

    def answer choice, probability: 0.8, extra: {}
      {
        'model'   => 'jev-1',
        'answers' => { 'preference' => { 'type'          => 'choice', 'choice' => choice, 'confidence' => 0.7,
                                         'probabilities' => { choice => probability } } },
      }.merge(extra)
    end

    test 'asks one choice question between the two documents, with no scale' do
      body = envelope[:body]
      question = body[:questions]['preference']

      assert_equal 'choice', question[:type]
      assert_equal %w[A B], question[:criteria].keys
      assert_includes question[:instructions], 'Judge relevance.'
      assert_equal({ 'A' => doc_a, 'B' => doc_b }, body[:state][:documents])
      assert_equal query.query_text, body[:state][:query]
    end

    test 'shows the second document first when swapped' do
      assert_equal({ 'A' => doc_b, 'B' => doc_a }, envelope(swapped: true)[:body][:state][:documents])
    end

    test 'is inert: the same arguments give the same, JSON-serialisable request' do
      assert_equal envelope, envelope
      assert_equal envelope.to_json, JSON.parse(envelope.to_json).to_json
    end

    test 'reads the winner and undoes the swap' do
      assert_equal 'a', adapter.apply_comparison(answer('A'), swapped: false)[:winner]
      assert_equal 'b', adapter.apply_comparison(answer('B'), swapped: false)[:winner]
      assert_equal 'b', adapter.apply_comparison(answer('A'), swapped: true)[:winner]
      assert_equal 'a', adapter.apply_comparison(answer('B'), swapped: true)[:winner]
    end

    test 'carries the probability, confidence and token usage' do
      result = adapter.apply_comparison(answer('A', extra: { 'usage' => { 'input_tokens' => 12, 'output_tokens' => 3 } }), swapped: false)

      assert_in_delta 0.8, result[:probability]
      assert_in_delta 0.7, result[:confidence]
      assert_equal [ 12, 3 ], result.values_at(:input_tokens, :output_tokens)
    end

    test 'an unreadable answer has no winner rather than a guess' do
      assert_nil adapter.apply_comparison({}, swapped: false)[:winner]
      assert_nil adapter.apply_comparison(answer('C'), swapped: false)[:winner]
      assert_nil adapter.apply_comparison({ 'answers' => { 'preference' => { 'choice' => nil } } }, swapped: true)[:winner]
    end

    test 'a near-even answer is a tie when the judge sets a tie band' do
      banded = Jev.new('ts-key', { llm_provider: 'typesafe_jev', jev_tie_band: '0.6' })

      assert_equal 'tie', banded.apply_comparison(answer('A', probability: 0.55), swapped: false)[:winner]
      assert_equal 'a', banded.apply_comparison(answer('A', probability: 0.9), swapped: false)[:winner]
      assert_equal 'a', adapter.apply_comparison(answer('A', probability: 0.55), swapped: false)[:winner]
    end

    test 'long documents are cut to keep the state under the cap' do
      big = { 'body' => 'x' * 100_000, 'more' => 'y' * 100_000 }
      state = adapter.comparison_envelope(query, big, big, system_prompt: '', swapped: false)[:body][:state]

      assert_operator state.to_json.length, :<=, Jev::MAX_STATE_CHARS
    end

    test 'a provider that cannot compare says so' do
      assert_raises(NotImplementedError) do
        OpenAi.new('key').comparison_envelope(query, doc_a, doc_b, system_prompt: '', swapped: false)
      end
      assert_raises(NotImplementedError) { OpenAi.new('key').apply_comparison({}, swapped: false) }
    end

    test 'only TypeSafe Jev is flagged pairwise' do
      assert_equal %w[typesafe_jev], LlmProvider.all.select(&:pairwise?).map(&:key)
    end
  end
end
