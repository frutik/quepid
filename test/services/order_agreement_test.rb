# frozen_string_literal: true

require 'test_helper'

class OrderAgreementTest < ActiveSupport::TestCase
  def agreement grades, positions = grades.each_index.to_a
    OrderAgreement.new(grades.zip(positions).map { |grade, position| { reference_grade: grade, position: position } })
  end

  test 'a perfect order scores 1 on every metric' do
    perfect = agreement([ 3, 2, 1, 0 ])

    assert_in_delta 1.0, perfect.pairwise_accuracy
    assert_in_delta 1.0, perfect.kendall_tau_b
    assert_in_delta 1.0, perfect.ndcg_at(10)
    assert_in_delta 1.0, perfect.top_k_overlap(2)
  end

  test 'a reversed order gives tau-b of -1 and no accuracy' do
    reversed = agreement([ 3, 2, 1, 0 ], [ 3, 2, 1, 0 ])

    assert_in_delta(-1.0, reversed.kendall_tau_b)
    assert_in_delta 0.0, reversed.pairwise_accuracy
    assert_in_delta 0.0, reversed.top_k_overlap(2)
  end

  test 'pairwise accuracy ignores pairs the reference grades alike' do
    # grades 1,1,0: only the two pairs against the 0 count; one is the wrong way round.
    assert_in_delta 0.5, agreement([ 1, 1, 0 ], [ 0, 2, 1 ]).pairwise_accuracy
  end

  test 'tau-b is tie-aware: a tie in the reference does not count as a miss' do
    # Two of the three pairs are ordered right and the third is a tie in the
    # reference, so tau-b is 2 / sqrt(2 * 3) rather than tau-a's 2/3.
    assert_in_delta Math.sqrt(2 / 3.0), agreement([ 2, 2, 0 ]).kendall_tau_b
  end

  test 'a list graded all alike has no defined agreement, not zero' do
    flat = agreement([ 1, 1, 1 ])

    assert_nil flat.kendall_tau_b
    assert_nil flat.pairwise_accuracy
    assert_nil flat.top_k_overlap(2)
    assert_nil agreement([ 0, 0 ]).ndcg_at(10)
  end

  test 'ndcg matches CalibrationScoreImpact on the same grades and order' do
    grades = [ 0, 3, 1, 2 ]
    impact = CalibrationScoreImpact.new(grades.each_with_index.map do |grade, i|
      { query_text: 'q', position: i, reference: grade, judge: grade }
    end)

    assert_in_delta impact.queries.first.reference_score, agreement(grades).ndcg_at(10)
  end

  test 'ndcg at k looks only at the top k' do
    # Best document placed 3rd: nothing relevant in the top 2.
    assert_in_delta 0.0, agreement([ 0, 0, 3 ]).ndcg_at(2)
  end

  test 'top-k overlap counts documents tied with the reference cut-off' do
    # reference top 1 is grade 3; the order puts a different grade-3 first.
    assert_in_delta 1.0, agreement([ 3, 3, 0 ], [ 1, 0, 2 ]).top_k_overlap(1)
  end

  test 'stability is tau-b between two orders of the same list' do
    assert_in_delta 1.0, OrderAgreement.stability(%w[a b c], %w[a b c])
    assert_in_delta(-1.0, OrderAgreement.stability(%w[a b c], %w[c b a]))
  end

  test 'macro average leaves out queries where the metric is undefined' do
    list = [ agreement([ 3, 2, 1 ]), agreement([ 1, 1, 1 ]), agreement([ 3, 2, 1 ], [ 2, 1, 0 ]) ]

    assert_in_delta 0.0, OrderAgreement.macro(list, :kendall_tau_b)
    assert_nil OrderAgreement.macro([ agreement([ 1, 1 ]) ], :kendall_tau_b)
  end
end
