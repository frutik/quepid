# frozen_string_literal: true

# One vector per document of a case, made by the case's embedder in document mode.
# Keyed on the case: a doc_id means nothing outside the case it came from.
class CreateDocumentEmbeddings < ActiveRecord::Migration[8.1]
  def change
    create_table :document_embeddings do |t|
      t.integer :case_id, null: false
      t.string  :doc_id, null: false, limit: 500
      t.string  :fingerprint, null: false, limit: 64 # Embedder#document_fingerprint (hex)
      t.string  :text_digest, null: false, limit: 64 # digest of the exact text sent
      t.integer :dimensions, null: false
      t.binary  :vector, null: false # packed little-endian float32, see DocumentEmbedding
      t.timestamps
    end

    add_index :document_embeddings, [ :case_id, :doc_id, :fingerprint ], unique: true,
                                                                         name:   'index_document_embeddings_on_case_doc_fingerprint'
  end
end
