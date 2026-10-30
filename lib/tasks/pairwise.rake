# frozen_string_literal: true

namespace :judges do
  desc 'Rank a calibration sample with a pairwise judge and print how its orders agree with the reference ' \
       '(docs/todo/pairwise_ranking_judges.md P4). Usage: judges:rank_sample[sample_id,judge_id,strategy]'
  task :rank_sample, [ :sample_id, :judge_id, :strategy ] => :environment do |_task, args|
    sample = CalibrationSample.find(args[:sample_id])
    judge = AiJudge.find(args[:judge_id])
    strategy = args[:strategy].presence || 'round_robin'
    abort "#{judge.name}'s provider cannot compare documents" unless LlmProvider.find(judge.judge_options[:llm_provider])&.pairwise?
    abort 'Sample must be drawn by queries' unless sample.by_queries?

    started = Time.current
    experiment = PairwiseExperiment.new(sample: sample, judge: judge, strategy: strategy)
    run = experiment.call
    puts "Order run #{run.id}: #{run.results.count} queries, #{run.comparisons_count} comparisons, " \
         "#{(Time.current - started).round(1)}s"

    report = experiment.report
    stability = report.delete(:stability)
    report.each do |arm, row|
      figures = PairwiseExperiment::METRICS.map { |metric| "#{metric}=#{row[metric]&.round(3).inspect}" }
      puts format('%-28<arm>s %<figures>s', arm: arm, figures: figures.join(' '))
    end
    puts "stability (forward vs reversed candidates, tau-b): #{stability&.round(3).inspect}"
  end
end
