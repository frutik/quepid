# frozen_string_literal: true

# == Schema Information
#
# Table name: snapshots
#
#  id             :integer          not null, primary key
#  diversity      :float(24)
#  diversity_meta :json
#  name           :string(250)
#  created_at     :datetime
#  updated_at     :datetime         not null
#  case_id        :integer
#  scorer_id      :bigint
#  try_id         :bigint
#
# Indexes
#
#  index_snapshots_on_case_id    (case_id)
#  index_snapshots_on_scorer_id  (scorer_id)
#  index_snapshots_on_try_id     (try_id)
#
# Foreign Keys
#
#  snapshots_ibfk_1  (case_id => cases.id)
#

class Snapshot < ApplicationRecord
  # Associations
  belongs_to  :case, optional: true # shouldn't be optional!
  belongs_to  :try, optional: true # shouldn't be optional!
  belongs_to  :scorer, optional: true # shouldn't be optional!

  # see the call back delete_associated_objects for special delete logic.
  has_many    :snapshot_queries, dependent: :destroy
  has_many :snapshot_docs,
           through: :snapshot_queries # , dependent: :destroy

  has_one_attached :snapshot_file

  # Validations
  validates :name, presence: true

  # Callbacks
  before_validation :set_defaults

  # Was the diversity computed (ComputeSnapshotDiversityJob) with the settings the case has now?
  # The title field belongs to the snapshot's own try, so it can't go stale; it is compared
  # between two snapshots instead (see #diversity_comparable_with?).
  def diversity_stale?
    meta = diversity_meta
    return false unless meta.is_a?(Hash) && 'done' == meta['status'] && self.case

    meta['fingerprint'] != self.case.effective_diversity_embedder&.document_fingerprint ||
      meta['depth'] != self.case.effective_diversity_depth
  end

  # Two diversity values are only comparable when made the same way.
  def diversity_comparable_with? other
    mine = diversity_meta
    theirs = other.diversity_meta
    return false unless mine.is_a?(Hash) && theirs.is_a?(Hash)

    %w[fingerprint title_field depth].all? { |key| mine[key] == theirs[key] }
  end
  # before_destroy :delete_associated_objects

  private

  def set_defaults
    self.name = "Snapshot #{Time.zone.now.strftime('%D')}" if name.blank?
  end

  # def delete_associated_objects
  #   puts 'I am about to delete associated objects'
  #   SnapshotDoc.joins(snapshot_query: :snapshot)
  #     .where(snapshot_queries: { snapshot: self })
  #     .delete_all
  #   snapshot_queries.delete_all
  # end
end
