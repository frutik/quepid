# frozen_string_literal: true

require 'test_helper'

class PairwiseOracleTest < ActiveSupport::TestCase
  let(:judge) do
    users(:judge_judy).tap do |j|
      j.judge_options = { llm_provider: 'typesafe_jev', llm_model: 'jev-latest',
                          llm_service_url: 'https://api.typesafe.ai', llm_timeout: 30 }
    end
  end
  let(:low) { query_doc_pairs(:starwars_qdp1) }
  let(:high) { query_doc_pairs(:starwars_qdp2) }
  let(:oracle) { PairwiseOracle.new(judge: judge) }

  # Answers that the document shown as "A" wins, whatever it is.
  def stub_jev choice = 'A'
    stub_request(:post, 'https://api.typesafe.ai/v1/systemone').to_return(
      status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { answers: { preference: { type: 'choice', choice: choice, confidence: 0.9,
                                       probabilities: { choice => 0.9 } } } }.to_json
    )
  end

  def swapped_for? pair_x, pair_y
    PairwiseSwap.swapped?(pair_x.query_text, pair_x.id, pair_y.id, oracle.rubric_version)
  end

  test 'asks once, stores the answer with the swap, and then reads it from the table' do
    request = stub_jev('A')
    first = oracle.compare(low, high)

    assert_includes [ :a, :b ], first
    assert_equal swapped_for?(low, high) ? :b : :a, first
    assert_equal 1, PreferenceComparison.count
    assert_equal (swapped_for?(low, high) ? 'b' : 'a'), PreferenceComparison.last.presented_first

    assert_equal first, oracle.compare(low, high)
    assert_requested request, times: 1
    assert_equal 1, oracle.calls
  end

  test 'is order-insensitive: the flipped question is the same answer, flipped' do
    stub_jev('A')
    forward = oracle.compare(low, high)
    flipped = oracle.compare(high, low)

    assert_equal({ a: :b, b: :a }.fetch(forward), flipped)
    assert_equal 1, PreferenceComparison.count
  end

  test 'a different prompt starts a fresh cache' do
    stub_jev
    oracle.compare(low, high)
    judge.system_prompt = 'Something else entirely.'
    PairwiseOracle.new(judge: judge).compare(low, high)

    assert_equal 2, PreferenceComparison.count
  end

  test 'a lost race reads the winner already stored instead of failing' do
    existing = PreferenceComparison.create!(judge: judge, rubric_version: oracle.rubric_version, query_text: low.query_text,
                                            query_doc_pair_a_id: low.id, query_doc_pair_b_id: high.id,
                                            presented_first: 'a', winner: 'b')

    assert_equal existing, oracle.send(:store, low, high, true, { winner: 'a' })
  end

  test 'an unreadable answer raises and stores nothing' do
    stub_request(:post, 'https://api.typesafe.ai/v1/systemone').to_return(status: 200, body: '{}',
                                                                          headers: { 'Content-Type' => 'application/json' })

    assert_raises(PairwiseOracle::Unreadable) { oracle.compare(low, high) }
    assert_equal 0, PreferenceComparison.count
  end

  test 'refuses documents of different queries' do
    other = QueryDocPair.where.not(query_text: low.query_text).first

    assert_raises(ArgumentError) { oracle.compare(low, other) }
  end

  test 'never creates a judgement' do
    stub_jev
    assert_no_difference 'Judgement.count' do
      oracle.compare(low, high)
    end
  end
end
