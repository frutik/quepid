# frozen_string_literal: true

# What a ranking judge said about one unordered pair of a query's documents:
# which is more relevant, 'a' or 'b' (the lower query_doc_pair id is always a),
# or a 'tie'. Never a judgement -- it carries no rating (docs/adr/0005 D1, D2).
class PreferenceComparison < ApplicationRecord
  WINNERS = %w[a b tie].freeze

  belongs_to :judge, class_name: 'AiJudge'
  belongs_to :pair_a, class_name: 'QueryDocPair', foreign_key: :query_doc_pair_a_id, inverse_of: false
  belongs_to :pair_b, class_name: 'QueryDocPair', foreign_key: :query_doc_pair_b_id, inverse_of: false

  validates :winner, inclusion: { in: WINNERS }
  validates :presented_first, inclusion: { in: %w[a b] }
  validates :query_doc_pair_b_id, comparison: { greater_than: :query_doc_pair_a_id }

  scope :for, ->(judge, rubric_version) { where(judge_id: judge.id, rubric_version: rubric_version) }
end
