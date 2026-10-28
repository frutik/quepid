# frozen_string_literal: true

require 'test_helper'

class DocumentEmbedderTest < ActiveSupport::TestCase
  URL = 'https://api.openai.com/v1/embeddings'

  let(:embedder) { embedders(:openai_small) }
  let(:kase)     { cases(:shared_with_team) }
  let(:service)  { DocumentEmbedder.new(kase, embedder) }

  def respond_with_vectors
    stub_request(:post, URL).to_return do |request|
      inputs = JSON.parse(request.body)['input']
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: inputs.each_index.map { |i| { index: i, embedding: Array.new(512) { |n| n == i ? 1.0 : 0.0 } } } }.to_json }
    end
  end

  test 'embeds documents without the query instruction and stores a vector per doc' do
    embedder.update!(input_template: 'Q: {query}')
    stub = respond_with_vectors

    result = service.embed({ 'a' => 'Star Wars', 'b' => 'Alien' })

    assert_equal 2, result.embedded
    assert_requested(:post, URL) { |request| [ 'Star Wars', 'Alien' ] == JSON.parse(request.body)['input'] }
    assert_requested stub
    stored = DocumentEmbedding.where(case_id: kase.id, fingerprint: embedder.document_fingerprint)

    assert_equal %w[a b], stored.order(:doc_id).pluck(:doc_id)
    assert_equal [ DocumentEmbedder.digest('Star Wars'), DocumentEmbedder.digest('Alien') ], stored.order(:doc_id).pluck(:text_digest)
    assert_equal 512, stored.find_by(doc_id: 'a').values.size
  end

  test 'pending skips documents whose vector is current and returns changed or new ones' do
    respond_with_vectors
    service.embed({ 'a' => 'Star Wars', 'b' => 'Alien' })

    pending = service.pending({ 'a' => 'Star Wars', 'b' => 'Aliens', 'c' => 'Blade Runner' })

    assert_equal({ 'b' => 'Aliens', 'c' => 'Blade Runner' }, pending)
    assert_equal({ 'a' => 'Star Wars' }, service.pending({ 'a' => 'Star Wars' }, force: true))
  end

  test 'a vector made with other settings is not current' do
    respond_with_vectors
    service.embed({ 'a' => 'Star Wars' })
    embedder.update!(model: 'text-embedding-3-large')

    assert_equal({ 'a' => 'Star Wars' }, DocumentEmbedder.new(kase, embedder).pending({ 'a' => 'Star Wars' }))
  end

  test 'editing only the instruction leaves the vectors current' do
    respond_with_vectors
    service.embed({ 'a' => 'Star Wars' })
    embedder.update!(provider: 'openai', input_template: 'Q: {query}')

    assert_empty DocumentEmbedder.new(kase, embedder).pending({ 'a' => 'Star Wars' })
  end

  test 'a rejected batch is recorded and does not stop the others' do
    provider = EmbedderProvider.find('openai').dup
    provider.max_batch_size = 1
    embedder.define_singleton_method(:provider_definition) { provider }
    stub_request(:post, URL)
      .to_return({ status: 400, body: { error: { message: 'too long' } }.to_json, headers: { 'Content-Type' => 'application/json' } },
                 { status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { data: [ { index: 0, embedding: Array.new(512, 0.1) } ] }.to_json })

    result = service.embed({ 'a' => 'one', 'b' => 'two' })

    assert_equal 1, result.embedded
    assert_equal 1, result.failed
    assert_match(/too long/, result.errors.first)
    assert_equal %w[b], DocumentEmbedding.where(case_id: kase.id).pluck(:doc_id)
  end
end
