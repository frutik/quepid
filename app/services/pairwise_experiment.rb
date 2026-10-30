# frozen_string_literal: true

# The offline experiment of docs/todo/pairwise_ranking_judges.md P4: a ranking
# judge orders every query of a calibration sample, and the order is measured
# against the sample's reference grades -- next to the search's own order and a
# pointwise judge's, on the same queries. It writes OrderRuns and
# PreferenceComparisons and nothing else: no judgement, no rating (R1).
class PairwiseExperiment
  RANKERS = { 'round_robin' => PairRanking::RoundRobin, 'comparison_sort' => PairRanking::ComparisonSort }.freeze
  METRICS = [ :pairwise_accuracy, :kendall_tau_b, :ndcg_at, :top_k_overlap ].freeze

  attr_reader :run

  # @param oracle [#compare] defaults to the judge's own PairwiseOracle
  def initialize sample:, judge:, strategy:, oracle: nil, created_by: nil
    raise ArgumentError, "unknown strategy #{strategy.inspect}" unless RANKERS.key?(strategy)

    @sample = sample
    @judge = judge
    @oracle = oracle || PairwiseOracle.new(judge: judge)
    @ranker = RANKERS.fetch(strategy).new(@oracle)
    @run = OrderRun.create!(sample: sample, judge: judge, strategy: strategy, created_by: created_by,
                            judge_snapshot: { system_prompt: judge.system_prompt, options: judge.judge_options })
  end

  # Ranks every sampled query, and once more with its candidates reversed, so
  # stability can be read off. Returns the run.
  def call
    @run.update!(status: 'running', started_at: Time.current)
    queries.each_value { |pairs| rank_query(pairs) }
    @run.update!(status: 'done', finished_at: Time.current, comparisons_count: @run.results.sum(:comparisons_used))
    @run
  rescue StandardError => e
    @run.update!(status: 'failed', error: e.message, finished_at: Time.current)
    raise
  end

  # The metrics for each arm, macro-averaged over the sample's queries.
  # @return [Hash] arm name => { metric => value, :queries => n }; the pointwise arm
  #   only when the judge has a finished calibration run on this sample
  def report
    arms = { 'search order' => search_order, "pairwise (#{@run.strategy})" => pairwise_order }
    pointwise = pointwise_order
    arms['pointwise'] = pointwise if pointwise
    arms.transform_values { |positions| summarise(positions) }.merge(stability: stability)
  end

  private

  # query_text => its QueryDocPairs in the search's order, top QUERY_DEPTH.
  def queries
    @queries ||= QueryDocPair.where(id: grades.keys).order(:position, :id).group_by(&:query_text)
      .transform_values { |pairs| pairs.first(CalibrationSample::QUERY_DEPTH) }
  end

  def grades
    @grades ||= @sample.sample_pairs.pluck(:query_doc_pair_id, :reference_rating).to_h
  end

  def rank_query pairs
    calls_before = calls
    forward = @ranker.rank(pairs)
    backward = @ranker.rank(pairs.reverse)
    @run.results.create!(
      query_text: pairs.first.query_text, ordered_pair_ids: forward.order.map(&:id),
      comparisons_used: forward.comparisons, cycles: forward.cycles,
      calls_used: calls - calls_before, tokens_used: tokens_for(pairs)
    )
    @stability_pairs ||= []
    @stability_pairs << [ forward.order.map(&:id), backward.order.map(&:id) ]
  end

  def calls
    @oracle.respond_to?(:calls) ? @oracle.calls : 0
  end

  # What this query's comparisons cost, as the cache recorded it.
  def tokens_for pairs
    PreferenceComparison.where(judge_id: @judge.id, query_doc_pair_a_id: pairs.map(&:id))
      .sum('COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)')
  end

  def search_order
    queries.transform_values { |pairs| pairs.each_with_index.to_h { |pair, index| [ pair.id, index ] } }
  end

  def pairwise_order
    @run.results.to_h do |result|
      [ result.query_text, result.ordered_pair_ids.each_with_index.to_h ]
    end
  end

  def pointwise_order
    answered = CalibrationRun.where(sample: @sample, judge: @judge, status: 'done').order(:id).last
    return nil unless answered

    ratings = answered.answers.pluck(:query_doc_pair_id, :rating, :unrateable).to_h { |id, rating, bad| [ id, bad ? nil : rating ] }
    queries.transform_values do |pairs|
      pairs.sort_by.with_index { |pair, index| [ -(ratings[pair.id] || -1), index ] }.each_with_index.to_h { |pair, i| [ pair.id, i ] }
    end
  end

  def summarise positions
    agreements = queries.filter_map do |query_text, pairs|
      order = positions[query_text]
      next unless order

      OrderAgreement.new(pairs.map { |pair| { reference_grade: grades[pair.id], position: order[pair.id] } })
    end
    METRICS.index_with { |metric| OrderAgreement.macro(agreements, metric) }.merge(queries: agreements.size)
  end

  def stability
    values = (@stability_pairs || []).filter_map { |forward, backward| OrderAgreement.stability(forward, backward) }
    values.empty? ? nil : values.sum / values.size
  end
end
