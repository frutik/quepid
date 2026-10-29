# frozen_string_literal: true

# The intra-list diversity (see DiversityCalculator) of one query's results, for the ILD scorer:
# embeds the results' titles with the case's diversity embedder, in document mode, and averages
# the pairwise cosine distances. Vectors are cached per case in DocumentEmbedding, so a result
# seen before costs nothing, whichever query or snapshot showed it.
class ResultDiversity
  Result = Struct.new(:value, :embedded, :failed, :errors, keyword_init: true)

  # @param kase [Case]
  # @param embedder [Embedder] normally Case#effective_diversity_embedder
  def initialize kase, embedder, timeout: nil
    @case = kase
    @embedder = embedder
    @documents = DocumentEmbedder.new(kase, embedder, timeout: timeout)
  end

  # @param docs [Array<Hash>] the top results in rank order, each { id:, text: } and, for EILD,
  #   :relevance (0 to 1); a blank text means the result has no title to embed and is left out
  # @param metric [Symbol] :ild, or :eild to weight the pairs by rank and relevance
  # @return [Result] value is nil when fewer than two results ended up with a vector
  def score docs, metric: :ild
    texts = docs.each_with_object({}) { |doc, by_id| by_id[doc[:id].to_s] ||= doc[:text] if doc[:text].present? }
    embedding = @documents.embed(@documents.pending(texts))
    vectors = DocumentEmbedding.vectors_for(case_id: @case.id, fingerprint: @documents.fingerprint, doc_ids: texts.keys)

    Result.new(value: value(docs, vectors, metric), embedded: embedding.embedded,
               failed: embedding.failed, errors: embedding.errors.uniq)
  end

  private

  def value docs, vectors, metric
    ranked = docs.map { |doc| vectors[doc[:id].to_s] }
    return DiversityCalculator.ild(ranked.compact) unless :eild == metric

    DiversityCalculator.eild(ranked, docs.map { |doc| doc[:relevance].to_f })
  end
end
