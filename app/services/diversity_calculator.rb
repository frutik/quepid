# frozen_string_literal: true

# Intra-list diversity (ILD) of a result list: the mean pairwise cosine distance between the
# vectors of its documents.
#
#   ILD = 2 / (n * (n - 1)) * sum over pairs i < j of (1 - cos(v_i, v_j))
#
# 0 when all documents are the same, 1 when they are orthogonal, 2 when opposite; with text
# embeddings it stays around 0 to 1. Cosine is computed in full, so vectors need not be unit
# length.
module DiversityCalculator
  # @param vectors [Array<Array<Float>>] one per document of the top k results
  # @return [Float, nil] nil when fewer than two documents have a usable vector: a list of
  #   zero or one has no diversity, which is not the same as 0 and mustn't drag a mean down
  def self.ild vectors
    units = vectors.filter_map { |vector| unit(vector) }
    n = units.size
    return nil if n < 2

    total = 0.0
    units.each_with_index do |left, i|
      ((i + 1)...n).each do |j|
        total += 1.0 - cosine(left, units[j])
      end
    end
    total * 2.0 / (n * (n - 1))
  end

  # Expected intra-list diversity (Vargas & Castells, "Rank and relevance in novelty and diversity
  # metrics for recommender systems", RecSys 2011, eq. 16): ILD where each pair counts for more the
  # higher the two results rank and the more relevant they are.
  #
  #   EILD = sum_k sum_{l != k} C_k * disc(k) * disc(l|k) * rel(k) * rel(l) * d(k, l)
  #
  # disc(k) = 1 / log2(k + 1), as in nDCG; disc(l|k) = disc(max(1, l - k)) is the rank of l
  # relative to k; rel is a probability, 0 to 1; C_k = C / sum_{l != k} disc(l|k) * rel(l), and
  # C = 1 / sum_k disc(k). With no discount and every rel 1 it is exactly `ild`.
  #
  # @param vectors [Array<Array<Float>, nil>] the results in rank order; nil for one with no
  #   vector (no title), which takes no part in the sums but keeps its rank
  # @param relevances [Array<Float>] rel for each result, 0 to 1 (an unrated result is 0)
  # @return [Float, nil] nil when fewer than two results have a vector
  def self.eild vectors, relevances
    items = eild_items(vectors, relevances)
    return nil if items.size < 2

    overall = 1.0 / items.sum { |item| discount(item[:rank]) }
    items.sum { |item| eild_term(item, items.reject { |other| other.equal?(item) }, overall) }
  end

  # The results with a usable vector, each with its unit vector, rank (from 1) and relevance.
  def self.eild_items vectors, relevances
    vectors.each_with_index.filter_map do |vector, index|
      unit = vector && unit(vector)
      { unit: unit, rank: index + 1, rel: relevances[index].to_f.clamp(0.0, 1.0) } if unit
    end
  end
  private_class_method :eild_items

  # One result's share of EILD: C_k * disc(k) * rel(k) * the relevance- and relative-rank-weighted
  # mean distance to the others.
  def self.eild_term item, others, overall
    weights = others.map { |other| discount([ 1, other[:rank] - item[:rank] ].max) * other[:rel] }
    total = weights.sum
    return 0.0 if total.zero? || item[:rel].zero?

    pairs = others.zip(weights).sum { |other, weight| weight * (1.0 - cosine(item[:unit], other[:unit])) }
    overall / total * discount(item[:rank]) * item[:rel] * pairs
  end
  private_class_method :eild_term

  # The nDCG rank discount, for a rank counted from 1.
  def self.discount rank
    1.0 / Math.log2(rank + 1)
  end
  private_class_method :discount

  # nil for the zero vector, which has no direction.
  def self.unit vector
    norm = Math.sqrt(vector.sum { |value| value * value })
    norm.zero? ? nil : vector.map { |value| value / norm }
  end
  private_class_method :unit

  def self.cosine left, right
    dot = 0.0
    left.each_index { |index| dot += left[index] * right[index] }
    dot.clamp(-1.0, 1.0)
  end
  private_class_method :cosine
end
