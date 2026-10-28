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
end
