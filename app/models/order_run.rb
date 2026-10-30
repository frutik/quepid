# frozen_string_literal: true

# One ranking judge over one calibration sample. Its results are orders, kept
# apart from judgements (docs/adr/0005 D2).
class OrderRun < ApplicationRecord
  STRATEGIES = %w[round_robin comparison_sort].freeze
  STATUSES = %w[queued running done failed cancelled].freeze

  belongs_to :sample, class_name: 'CalibrationSample', foreign_key: :calibration_sample_id, inverse_of: false
  belongs_to :judge, class_name: 'AiJudge'
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :results, class_name: 'OrderResult', inverse_of: :run, dependent: :delete_all

  validates :strategy, inclusion: { in: STRATEGIES }
  validates :status, inclusion: { in: STATUSES }
end
