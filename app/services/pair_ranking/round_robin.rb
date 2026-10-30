# frozen_string_literal: true

module PairRanking
  # Compare every pair of candidates once and rank by wins (a tie is half a
  # win), keeping the search's own order between equals. The exhaustive
  # baseline: n(n-1)/2 comparisons, and tolerant of a judge that contradicts
  # itself, which it counts as cycles.
  class RoundRobin
    Result = Struct.new(:order, :comparisons, :cycles)

    def initialize oracle
      @oracle = oracle
    end

    # @param items [Array] candidates, in the search's order
    # @return [Result] order is best first
    def rank items
      score = Array.new(items.size, 0.0)
      beats = Array.new(items.size) { Array.new(items.size, false) }
      comparisons = 0

      items.each_index.to_a.combination(2) do |i, j|
        comparisons += 1
        case @oracle.compare(items[i], items[j])
        when :a
          score[i] += 1
          beats[i][j] = true
        when :b
          score[j] += 1
          beats[j][i] = true
        else
          score[i] += 0.5
          score[j] += 0.5
        end
      end

      order = items.each_index.sort_by { |index| [ -score[index], index ] }.map { |index| items[index] }
      Result.new(order, comparisons, cycles(beats))
    end

    private

    def cycles beats
      count = 0
      beats.each_index.to_a.combination(3) do |i, j, k|
        count += 1 if (beats[i][j] && beats[j][k] && beats[k][i]) || (beats[j][i] && beats[k][j] && beats[i][k])
      end
      count
    end
  end
end
