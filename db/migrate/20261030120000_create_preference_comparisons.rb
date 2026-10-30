# frozen_string_literal: true

# The cache of a ranking judge's answers (docs/adr/0005 D2): one row per
# unordered pair of one query's documents, kept apart from judgements so that
# asking never moves a rating.
class CreatePreferenceComparisons < ActiveRecord::Migration[8.1]
  def change
    create_table :preference_comparisons do |t|
      t.integer :judge_id, null: false
      t.string  :rubric_version, null: false, limit: 64
      t.string  :query_text, limit: 2048
      t.bigint  :query_doc_pair_a_id, null: false
      t.bigint  :query_doc_pair_b_id, null: false
      t.string  :presented_first, null: false, limit: 1
      t.string  :winner, null: false, limit: 4
      t.float   :probability
      t.float   :confidence
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end

    add_index :preference_comparisons, [ :judge_id, :rubric_version, :query_doc_pair_a_id, :query_doc_pair_b_id ],
              unique: true, name: 'index_preference_comparisons_on_judge_rubric_pair'
    add_index :preference_comparisons, :query_doc_pair_a_id
    add_index :preference_comparisons, :query_doc_pair_b_id
    add_foreign_key :preference_comparisons, :users, column: :judge_id, on_delete: :cascade
    add_foreign_key :preference_comparisons, :query_doc_pairs, column: :query_doc_pair_a_id, on_delete: :cascade
    add_foreign_key :preference_comparisons, :query_doc_pairs, column: :query_doc_pair_b_id, on_delete: :cascade
  end
end
