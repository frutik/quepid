# frozen_string_literal: true

require 'test_helper'

class DiversityCalculatorTest < ActiveSupport::TestCase
  test 'identical vectors are not diverse at all' do
    assert_in_delta 0.0, DiversityCalculator.ild([ [ 1.0, 2.0 ], [ 1.0, 2.0 ], [ 2.0, 4.0 ] ]), 1.0e-12
  end

  test 'orthogonal vectors are at distance 1' do
    assert_in_delta 1.0, DiversityCalculator.ild([ [ 1.0, 0.0, 0.0 ], [ 0.0, 1.0, 0.0 ], [ 0.0, 0.0, 1.0 ] ]), 1.0e-12
  end

  test 'opposite vectors are at distance 2' do
    assert_in_delta 2.0, DiversityCalculator.ild([ [ 1.0, 0.0 ], [ -1.0, 0.0 ] ]), 1.0e-12
  end

  test 'is the mean over all pairs' do
    # cos distances: a-b 0 (same direction), a-c 1, b-c 1 => mean 2/3
    assert_in_delta 2.0 / 3, DiversityCalculator.ild([ [ 1.0, 0.0 ], [ 3.0, 0.0 ], [ 0.0, 1.0 ] ]), 1.0e-12
  end

  test 'does not depend on the length of the vectors or their order' do
    vectors = [ [ 1.0, 2.0, 3.0 ], [ -1.0, 0.5, 2.0 ], [ 0.1, 0.1, 0.9 ] ]
    scaled = vectors.each_with_index.map { |vector, index| vector.map { |value| value * (index + 2) } }

    assert_in_delta DiversityCalculator.ild(vectors), DiversityCalculator.ild(scaled), 1.0e-12
    assert_in_delta DiversityCalculator.ild(vectors), DiversityCalculator.ild(vectors.reverse), 1.0e-12
  end

  test 'is nil, not 0, for fewer than two vectors' do
    assert_nil DiversityCalculator.ild([])
    assert_nil DiversityCalculator.ild([ [ 1.0, 0.0 ] ])
  end

  test 'ignores a zero vector, which has no direction' do
    assert_in_delta 1.0, DiversityCalculator.ild([ [ 1.0, 0.0 ], [ 0.0, 0.0 ], [ 0.0, 1.0 ] ]), 1.0e-12
    assert_nil DiversityCalculator.ild([ [ 1.0, 0.0 ], [ 0.0, 0.0 ] ])
  end

  test 'never goes below 0 through rounding' do
    value = DiversityCalculator.ild([ [ 0.1, 0.2, 0.3 ], [ 0.1, 0.2, 0.3 ] ])

    assert_operator value, :>=, 0.0
  end

  describe 'eild' do
    def disc rank
      1.0 / Math.log2(rank + 1)
    end

    test 'two results: both orderings of the one pair, weighted and normalised' do
      # d = 1 (orthogonal). Result 1 (rel 1): other is rank 2, relative rank 1. Result 2 (rel 0.5):
      # other is rank 1, relative rank max(1, -1) = 1. Each inner term is normalised by its own
      # weights, so each inner mean is d = 1, and the outer weights are disc(k) * rel(k) / sum disc.
      expected = ((disc(1) * 1.0) + (disc(2) * 0.5)) / (disc(1) + disc(2))

      assert_in_delta expected, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 1.0, 0.5 ]), 1.0e-12
    end

    test 'is the mean cosine distance when relevance is full, whatever the discount, for two results' do
      assert_in_delta 1.0, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 1.0, 1.0 ]), 1.0e-12
    end

    test 'identical results are not diverse, relevant or not' do
      assert_in_delta 0.0, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 2.0, 0.0 ], [ 3.0, 0.0 ] ], [ 1.0, 0.7, 0.2 ]), 1.0e-12
    end

    test 'a result that is not relevant adds no diversity' do
      assert_in_delta 0.0, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 0.0, 0.0 ]), 1.0e-12
    end

    test 'moving the relevant, different result up raises it' do
      near = [ [ 1.0, 0.0 ], [ 1.0, 0.0 ], [ 0.0, 1.0 ] ]
      relevant_far_down = DiversityCalculator.eild(near, [ 1.0, 1.0, 1.0 ])
      far_dropped = DiversityCalculator.eild(near, [ 1.0, 1.0, 0.0 ])

      assert_operator relevant_far_down, :>, far_dropped
    end

    test 'a different result at the top counts for more than one at the bottom' do
      top = DiversityCalculator.eild([ [ 0.0, 1.0 ], [ 1.0, 0.0 ], [ 1.0, 0.0 ] ], [ 1.0, 1.0, 1.0 ])
      bottom = DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 1.0, 1.0, 1.0 ])

      assert_operator top, :>, bottom
    end

    test 'does not depend on the length of the vectors' do
      vectors = [ [ 1.0, 2.0, 3.0 ], [ -1.0, 0.5, 2.0 ], [ 0.1, 0.1, 0.9 ] ]
      scaled = vectors.each_with_index.map { |vector, index| vector.map { |value| value * (index + 2) } }
      relevances = [ 1.0, 0.5, 0.25 ]

      assert_in_delta DiversityCalculator.eild(vectors, relevances), DiversityCalculator.eild(scaled, relevances), 1.0e-12
    end

    test 'a result with no vector keeps its rank but takes no part' do
      with_gap = DiversityCalculator.eild([ [ 1.0, 0.0 ], nil, [ 0.0, 1.0 ] ], [ 1.0, 1.0, 1.0 ])
      compressed = DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 1.0, 1.0 ])

      assert_in_delta 1.0, with_gap, 1.0e-12
      assert_in_delta 1.0, compressed, 1.0e-12
    end

    test 'is nil for fewer than two results with a vector' do
      assert_nil DiversityCalculator.eild([], [])
      assert_nil DiversityCalculator.eild([ [ 1.0, 0.0 ], nil ], [ 1.0, 1.0 ])
      assert_nil DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 0.0 ] ], [ 1.0, 1.0 ])
    end

    test 'treats a missing or out-of-range relevance as 0 to 1' do
      assert_in_delta 1.0, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], [ 5.0, 5.0 ]), 1.0e-12
      assert_in_delta 0.0, DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ], []), 1.0e-12
    end

    test 'reduces to ild when discount and relevance are flat' do
      # Same weights for every pair is what ild computes; the only discount in eild is log, so
      # check the limit the paper states on the pair that has no rank effect (two results).
      assert_in_delta DiversityCalculator.ild([ [ 1.0, 0.0 ], [ 1.0, 1.0 ] ]),
                      DiversityCalculator.eild([ [ 1.0, 0.0 ], [ 1.0, 1.0 ] ], [ 1.0, 1.0 ]), 1.0e-12
    end
  end
end
