# frozen_string_literal: true

require 'test_helper'

class DocumentEmbeddingTest < ActiveSupport::TestCase
  let(:kase) { cases(:one) }

  def store rows, fingerprint: 'fp1', case_id: kase.id
    DocumentEmbedding.store(case_id: case_id, fingerprint: fingerprint, rows: rows)
  end

  test 'a vector survives the round trip, as float32' do
    vector = [ 0.5, -0.25, 1.0e-3, 123.0 ]
    store([ { doc_id: 'a', text_digest: 'd1', vector: vector } ])

    row = DocumentEmbedding.find_by!(case_id: kase.id, doc_id: 'a')

    assert_equal 4, row.dimensions
    assert_equal 16, row.vector.bytesize
    vector.zip(row.values).each { |expected, actual| assert_in_delta expected, actual, 1.0e-6 * [ expected.abs, 1 ].max }
  end

  test 'storing the same doc and fingerprint again replaces the row' do
    store([ { doc_id: 'a', text_digest: 'd1', vector: [ 1.0, 0.0 ] } ])
    store([ { doc_id: 'a', text_digest: 'd2', vector: [ 0.0, 1.0 ] } ])

    rows = DocumentEmbedding.where(case_id: kase.id, doc_id: 'a')

    assert_equal 1, rows.count
    assert_equal 'd2', rows.first.text_digest
    assert_equal [ 0.0, 1.0 ], rows.first.values
  end

  test 'keeps a row per fingerprint and per case' do
    store([ { doc_id: 'a', text_digest: 'd', vector: [ 1.0 ] } ])
    store([ { doc_id: 'a', text_digest: 'd', vector: [ 1.0 ] } ], fingerprint: 'fp2')
    store([ { doc_id: 'a', text_digest: 'd', vector: [ 1.0 ] } ], case_id: cases(:two).id)

    assert_equal 3, DocumentEmbedding.where(doc_id: 'a').count
  end

  test 'doc ids that differ only in case are different documents' do
    store([ { doc_id: 'Doc', text_digest: 'd', vector: [ 1.0 ] }, { doc_id: 'doc', text_digest: 'd', vector: [ 2.0 ] } ])

    assert_equal 2, DocumentEmbedding.where(case_id: kase.id).count
  end

  test 'digests_for and vectors_for read a case\'s rows for one fingerprint' do
    store([ { doc_id: 'a', text_digest: 'da', vector: [ 1.0, 0.5 ] }, { doc_id: 'b', text_digest: 'db', vector: [ 1.0, 0.5 ] } ])
    store([ { doc_id: 'a', text_digest: 'other', vector: [ 9.0, 9.0 ] } ], fingerprint: 'fp2')

    assert_equal({ 'a' => 'da' }, DocumentEmbedding.digests_for(case_id: kase.id, fingerprint: 'fp1', doc_ids: %w[a c]))
    assert_equal({ 'a' => [ 1.0, 0.5 ] }, DocumentEmbedding.vectors_for(case_id: kase.id, fingerprint: 'fp1', doc_ids: %w[a c]))
  end

  test 'refuses a vector that does not match its dimensions or is too large' do
    row = DocumentEmbedding.new(case_id: kase.id, doc_id: 'a', fingerprint: 'fp', text_digest: 'd', dimensions: 3,
                                vector: DocumentEmbedding.pack([ 1.0, 2.0 ]))

    assert_not row.valid?
    assert row.errors.added?(:vector, 'has 2 components, expected 3')

    row.assign_attributes(dimensions: DocumentEmbedding::MAX_DIMENSIONS + 1, vector: 'x' * 4 * (DocumentEmbedding::MAX_DIMENSIONS + 1))

    assert_not row.valid?
    assert row.errors.key?(:dimensions)
  end

  test 'deleting a case deletes its embeddings' do
    store([ { doc_id: 'a', text_digest: 'd', vector: [ 1.0 ] } ])

    kase.destroy

    assert_equal 0, DocumentEmbedding.where(case_id: kase.id).count
  end
end
