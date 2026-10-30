# frozen_string_literal: true

require 'test_helper'

module PairRanking
  class RankersTest < ActiveSupport::TestCase
    # An oracle from a table of who beats whom; counts what it is asked.
    class FakeOracle
      attr_reader :asked

      def initialize prefers
        @prefers = prefers # { [x, y] => winner }
        @asked = 0
      end

      def compare left, right
        @asked += 1
        winner = @prefers[[ left, right ]] || @prefers[[ right, left ]]
        return :tie if winner.nil?

        winner == left ? :a : :b
      end
    end

    # A consistent oracle: lower number wins.
    def consistent
      Object.new.tap do |oracle|
        oracle.define_singleton_method(:compare) { |x, y| x < y ? :a : :b }
      end
    end

    [ RoundRobin, ComparisonSort ].each do |ranker|
      test "#{ranker.name.demodulize}: a consistent oracle gives the true order, whatever the input order" do
        assert_equal [ 1, 2, 3, 4, 5 ], ranker.new(consistent).rank([ 3, 1, 5, 2, 4 ]).order
        assert_equal [ 1, 2, 3, 4, 5 ], ranker.new(consistent).rank([ 5, 4, 3, 2, 1 ]).order
      end

      test "#{ranker.name.demodulize}: ties keep the search's order" do
        assert_equal %w[c a b], ranker.new(FakeOracle.new({})).rank(%w[c a b]).order
      end

      test "#{ranker.name.demodulize}: handles one and no candidates" do
        assert_equal [ 7 ], ranker.new(consistent).rank([ 7 ]).order
        assert_equal [], ranker.new(consistent).rank([]).order
      end
    end

    test 'round-robin asks exactly n(n-1)/2 questions' do
      oracle = FakeOracle.new({})
      result = RoundRobin.new(oracle).rank((1..6).to_a)

      assert_equal 15, result.comparisons
      assert_equal 15, oracle.asked
      assert_equal 0, result.cycles
    end

    test 'comparison sort asks at most n ceil(log2 n) questions' do
      result = ComparisonSort.new(consistent).rank((1..16).to_a.shuffle)

      assert_operator result.comparisons, :<=, 16 * 4
      assert_nil result.cycles
    end

    test 'round-robin terminates on a cycle and reports it' do
      oracle = FakeOracle.new({ %w[a b] => 'a', %w[b c] => 'b', %w[c a] => 'c' })
      result = RoundRobin.new(oracle).rank(%w[a b c])

      assert_equal 1, result.cycles
      assert_equal %w[a b c], result.order # one win each: the search's order
    end

    test 'comparison sort terminates on a cycle' do
      oracle = FakeOracle.new({ %w[a b] => 'a', %w[b c] => 'b', %w[c a] => 'c' })

      assert_equal 3, ComparisonSort.new(oracle).rank(%w[a b c]).order.size
    end
  end
end
