# frozen_string_literal: true

require 'test_helper'

class PairwiseSwapTest < ActiveSupport::TestCase
  test 'is stable for the same comparison' do
    assert_equal PairwiseSwap.swapped?('q', 1, 2, 'v'), PairwiseSwap.swapped?('q', 1, 2, 'v')
  end

  test 'swaps about half of all comparisons' do
    swapped = (1..4000).count { |id| PairwiseSwap.swapped?('q', id, id + 1, 'v') }

    assert_in_delta 2000, swapped, 200
  end

  test 'a new rubric reshuffles' do
    assert_not_equal((1..200).map { |id| PairwiseSwap.swapped?('q', id, id + 1, 'v1') },
                     (1..200).map { |id| PairwiseSwap.swapped?('q', id, id + 1, 'v2') })
  end
end
