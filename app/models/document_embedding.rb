# frozen_string_literal: true

# == Schema Information
#
# Table name: document_embeddings
#
#  id          :bigint           not null, primary key
#  dimensions  :integer          not null
#  doc_id      :string(500)      not null
#  fingerprint :string(64)       not null
#  text_digest :string(64)       not null
#  vector      :binary           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  case_id     :integer          not null
#
# Indexes
#
#  index_document_embeddings_on_case_doc_fingerprint  (case_id,doc_id,fingerprint) UNIQUE
#

# The vector of one document of a case, made by the case's embedder in document mode.
#
# Keyed on the case, never globally: a doc_id means nothing outside the case it came
# from, and a case can switch search endpoints between tries without its documents'
# vectors going stale. `fingerprint` is Embedder#document_fingerprint and `text_digest`
# a digest of the exact text sent, so a row is current when both still match.
#
# The vector is binary, not JSON: 4 bytes a component instead of ~12, and nothing reads
# it outside Ruby. 'e' packs little-endian float32, so a vector reads back the same
# whatever machine wrote it.
class DocumentEmbedding < ApplicationRecord
  # A MySQL BLOB holds 64 KB; the limit applies on every adapter so they behave alike.
  MAX_DIMENSIONS = 65_535 / 4

  belongs_to :case

  validates :doc_id, :fingerprint, :text_digest, presence: true
  validates :dimensions, numericality: { only_integer: true, in: 1..MAX_DIMENSIONS }
  validates :vector, presence: true
  validate :vector_has_dimensions

  def self.pack vector
    vector.pack('e*')
  end

  def self.unpack bytes
    bytes.to_s.b.unpack('e*')
  end

  # Writes rows for a case in one statement. `rows` are hashes with :doc_id, :text_digest
  # and :vector (an Array of Float); an existing row for the same doc and fingerprint is
  # replaced.
  def self.store case_id:, fingerprint:, rows:
    return if rows.empty?

    now = Time.current
    records = rows.map do |row|
      { case_id:     case_id,
        doc_id:      row.fetch(:doc_id),
        fingerprint: fingerprint,
        text_digest: row.fetch(:text_digest),
        dimensions:  row.fetch(:vector).size,
        vector:      pack(row.fetch(:vector)),
        created_at:  now,
        updated_at:  now }
    end

    # PostgreSQL and SQLite need the conflict target named, or they conflict on the primary
    # key, which never matches; MySQL rejects it and matches any unique index.
    if AdapterFunctions.mysql?
      upsert_all(records)
    else
      upsert_all(records, unique_by: :index_document_embeddings_on_case_doc_fingerprint)
    end
  end

  # { doc_id => text_digest } of the case's rows with this fingerprint, without loading the
  # vectors: enough to tell which documents are already embedded.
  def self.digests_for case_id:, fingerprint:, doc_ids:
    where(case_id: case_id, fingerprint: fingerprint, doc_id: doc_ids).pluck(:doc_id, :text_digest).to_h
  end

  # { doc_id => Array<Float> } for these documents.
  def self.vectors_for case_id:, fingerprint:, doc_ids:
    where(case_id: case_id, fingerprint: fingerprint, doc_id: doc_ids)
      .pluck(:doc_id, :vector)
      .to_h { |doc_id, bytes| [ doc_id, unpack(bytes) ] }
  end

  def values
    self.class.unpack(vector)
  end

  private

  def vector_has_dimensions
    return if vector.blank? || dimensions.blank?

    errors.add(:vector, "has #{vector.bytesize / 4} components, expected #{dimensions}") unless vector.bytesize == dimensions * 4
  end
end
