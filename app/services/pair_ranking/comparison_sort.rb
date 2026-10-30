# frozen_string_literal: true

module PairRanking
  # A stable merge sort with the oracle as comparator: about n log n
  # comparisons instead of n². A tie keeps the search's order. It never
  # notices a judge contradicting itself, which is why it reports no cycles.
  class ComparisonSort
    Result = Struct.new(:order, :comparisons, :cycles)

    def initialize oracle
      @oracle = oracle
    end

    def rank items
      @comparisons = 0
      Result.new(sort(items), @comparisons, nil)
    end

    private

    def sort items
      return items if items.size < 2

      middle = items.size / 2
      merge(sort(items[0...middle]), sort(items[middle..]))
    end

    def merge left, right
      merged = []
      until left.empty? || right.empty?
        @comparisons += 1
        merged << (:b == @oracle.compare(left.first, right.first) ? right.shift : left.shift)
      end
      merged + left + right
    end
  end
end
