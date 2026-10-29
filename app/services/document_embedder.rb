# frozen_string_literal: true

# Embeds the documents of one case with its embedder, in document mode, and keeps the
# vectors in DocumentEmbedding. Work is batch by batch: a batch the provider rejects is
# recorded and leaves its documents without a vector, and the other batches still run.
class DocumentEmbedder
  Result = Struct.new(:embedded, :failed, :errors, keyword_init: true)

  # @param kase [Case]
  # @param embedder [Embedder]
  # @param timeout [Integer, nil] seconds per request; defaults to the embedder's own
  def initialize kase, embedder, timeout: nil
    @case = kase
    @embedder = embedder
    @timeout = timeout
    @fingerprint = embedder.document_fingerprint
  end

  attr_reader :fingerprint

  # Digest of a text, stored with its vector so a changed text is noticed.
  def self.digest text
    Digest::SHA256.hexdigest(text)[0, 16]
  end

  # The documents that still need a vector: those with none for the current fingerprint,
  # or with one made from a different text -- all of them with `force`.
  # @param texts [Hash{String => String}] doc_id => text
  # @return [Hash{String => String}] the subset of texts to embed
  def pending texts, force: false
    return texts if force

    stored = DocumentEmbedding.digests_for(case_id: @case.id, fingerprint: @fingerprint, doc_ids: texts.keys)
    texts.reject { |doc_id, text| stored[doc_id] == self.class.digest(text) }
  end

  # @param texts [Hash{String => String}] doc_id => text to embed
  # @return [Result]
  def embed texts
    result = Result.new(embedded: 0, failed: 0, errors: [])

    texts.each_slice(@embedder.provider_definition.max_batch_size) do |batch|
      embed_batch(batch, result)
    end

    result
  end

  private

  def embed_batch batch, result
    vectors = @embedder.embed(batch.map(&:last), timeout: @timeout, input_type: :document)
    raise EmbedderAdapters::Error, "vectors of more than #{DocumentEmbedding::MAX_DIMENSIONS} dimensions can't be stored" if vectors.any? { |vector| vector.size > DocumentEmbedding::MAX_DIMENSIONS }

    rows = batch.zip(vectors).map do |(doc_id, text), vector|
      { doc_id: doc_id, text_digest: self.class.digest(text), vector: vector }
    end
    DocumentEmbedding.store(case_id: @case.id, fingerprint: @fingerprint, rows: rows)
    result.embedded += batch.size
  rescue EmbedderAdapters::Error => e
    result.failed += batch.size
    result.errors << e.message
  end
end
