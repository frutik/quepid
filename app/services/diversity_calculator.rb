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
