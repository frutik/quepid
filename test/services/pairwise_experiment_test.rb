# frozen_string_literal: true

require 'test_helper'

class PairwiseExperimentTest < ActiveSupport::TestCase
  let(:judge) { users(:judge_judy) }
  let(:book) { books(:book_of_star_wars_judgements) }
  let(:first) { query_doc_pairs(:starwars_qdp1) }  # search position 1
  let(:second) { query_doc_pairs(:starwars_qdp2) } # search position 2

  # Prefers whichever pair the table says is better.
  class FakeOracle
    attr_reader :calls

    def initialize better
      @better = better
      @calls = 0
    end

    def compare left, right
      @calls += 1
      @better.index(left.id) < @better.index(right.id) ? :a : :b
    end
  end

  def sample reference_grades
    CalibrationSample.create!(book: book, reference: users(:random), unit: 'queries', pairs_count: reference_grades.size).tap do |sample|
      reference_grades.each do |pair, grade|
        CalibrationSamplePair.create!(sample: sample, query_doc_pair: pair, reference_rating: grade)
      end
    end
  end

  test 'ranks every query, stores an order apart from any rating, and reports each arm' do
    sample = sample(first => 0, second => 3) # the humans prefer the second, the search put it second
    experiment = PairwiseExperiment.new(sample: sample, judge: judge, strategy: 'round_robin',
                                        oracle: FakeOracle.new([ second.id, first.id ]))

    assert_no_difference [ 'Judgement.count', 'Rating.count' ] do
      experiment.call
    end

    run = experiment.run

    assert_equal 'done', run.status
    assert_equal [ [ second.id, first.id ] ], run.results.map(&:ordered_pair_ids)
    assert_equal 1, run.comparisons_count

    report = experiment.report

    assert_in_delta 1.0, report['pairwise (round_robin)'][:kendall_tau_b]
    assert_in_delta(-1.0, report['search order'][:kendall_tau_b])
    assert_in_delta 1.0, report[:stability]
    assert_not report.key?('pointwise'), 'no pointwise run on this sample'
  end

  test 'a failure marks the run failed and raises' do
    broken = Object.new
    def broken.compare(_left, _right) = raise('provider down')
    experiment = PairwiseExperiment.new(sample: sample(first => 0, second => 3), judge: judge,
                                        strategy: 'comparison_sort', oracle: broken)

    assert_raises(RuntimeError) { experiment.call }
    assert_equal 'failed', experiment.run.reload.status
    assert_equal 'provider down', experiment.run.error
  end

  test 'refuses an unknown strategy' do
    assert_raises(ArgumentError) { PairwiseExperiment.new(sample: sample(first => 0), judge: judge, strategy: 'blitzrank') }
  end
end
