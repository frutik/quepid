# frozen_string_literal: true

require 'test_helper'

class ResultDiversityTest < ActiveSupport::TestCase
  URL = 'https://api.openai.com/v1/embeddings'

  let(:embedder) { embedders(:openai_small) }
  let(:kase)     { cases(:shared_with_team) }

  VECTORS = {
    'Star Wars'  => [ 1.0, 0.0, 0.0 ],
    'The Empire' => [ 1.0, 0.0, 0.0 ],
    'Casablanca' => [ 0.0, 1.0, 0.0 ],
    'Alien'      => [ 0.0, 0.0, 1.0 ],
  }.freeze

  def respond_with_table
    stub_request(:post, URL).to_return do |request|
      inputs = JSON.parse(request.body)['input']
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: inputs.each_with_index.map { |text, i| { index: i, embedding: VECTORS.fetch(text) + Array.new(509, 0.0) } } }.to_json }
    end
  end

  def doc id, text
    { id: id, text: text }
  end

  test 'is the mean pairwise distance of the results' do
    respond_with_table

    result = ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', 'Casablanca'), doc('c', 'Alien') ])

    assert_in_delta 1.0, result.value, 1.0e-6
    assert_equal 3, result.embedded
    assert_empty result.errors
  end

  test 'results that are alike are not diverse' do
    respond_with_table

    result = ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', 'The Empire') ])

    assert_in_delta 0.0, result.value, 1.0e-6
  end

  test 'a result without a title is left out, and fewer than two results have no value' do
    respond_with_table

    assert_nil ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', nil) ]).value
    assert_nil ResultDiversity.new(kase, embedder).score([]).value
  end

  test 'embeds a result once, whichever query shows it' do
    respond_with_table
    service = ResultDiversity.new(kase, embedder)
    service.score([ doc('a', 'Star Wars'), doc('b', 'Casablanca') ])
    WebMock::RequestRegistry.instance.reset!

    result = service.score([ doc('b', 'Casablanca'), doc('c', 'Alien') ])

    assert_requested(:post, URL, times: 1) { |request| [ 'Alien' ] == JSON.parse(request.body)['input'] }
    assert_equal 1, result.embedded
    assert_in_delta 1.0, result.value, 1.0e-6
  end

  test 'reports a provider failure and does not invent a value from what is left' do
    stub_request(:post, URL).to_return(status: 500, body: 'down')

    result = ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', 'Casablanca') ])

    assert_nil result.value
    assert_not_empty result.errors
  end

  test 'sends documents as documents, without the query instruction' do
    embedder.update!(input_template: 'Q: {query}')
    respond_with_table

    ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', 'Alien') ])

    assert_requested(:post, URL) { |request| [ 'Star Wars', 'Alien' ] == JSON.parse(request.body)['input'] }
  end

  describe 'eild' do
    test 'weights the pair by rank and relevance' do
      respond_with_table
      docs = [ doc('a', 'Star Wars').merge(relevance: 1.0), doc('b', 'Casablanca').merge(relevance: 0.5) ]

      result = ResultDiversity.new(kase, embedder).score(docs, metric: :eild)

      disc = ->(rank) { 1.0 / Math.log2(rank + 1) }
      assert_in_delta (disc.call(1) + (0.5 * disc.call(2))) / (disc.call(1) + disc.call(2)), result.value, 1.0e-6
    end

    test 'is ild for two fully relevant results' do
      respond_with_table
      docs = [ doc('a', 'Star Wars').merge(relevance: 1.0), doc('b', 'Casablanca').merge(relevance: 1.0) ]

      assert_in_delta 1.0, ResultDiversity.new(kase, embedder).score(docs, metric: :eild).value, 1.0e-6
    end

    test 'unrated results are not relevant, so nothing is diverse' do
      respond_with_table

      result = ResultDiversity.new(kase, embedder).score([ doc('a', 'Star Wars'), doc('b', 'Casablanca') ], metric: :eild)

      assert_in_delta 0.0, result.value, 1.0e-6
    end

    test 'a result without a title keeps its rank' do
      respond_with_table
      docs = [ doc('a', 'Star Wars'), doc('x', nil), doc('b', 'Casablanca') ].map { |d| d.merge(relevance: 1.0) }

      assert_in_delta 1.0, ResultDiversity.new(kase, embedder).score(docs, metric: :eild).value, 1.0e-6
    end
  end
end
