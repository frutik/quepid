# frozen_string_literal: true

# A ranking judge's pass over a calibration sample, and the order it gave each
# query (docs/adr/0005 D2). Orders are not ratings: nothing here is a judgement.
class CreateOrderRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :order_runs do |t|
      t.bigint  :calibration_sample_id, null: false
      t.integer :judge_id, null: false
      t.integer :created_by_id
      t.string  :status, null: false, default: 'queued', limit: 20
      t.string  :strategy, null: false, limit: 20
      t.json    :judge_snapshot
      t.integer :comparisons_count, null: false, default: 0
      t.text    :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :order_runs, :calibration_sample_id
    add_index :order_runs, :judge_id
    add_foreign_key :order_runs, :calibration_samples, on_delete: :cascade
    add_foreign_key :order_runs, :users, column: :judge_id, on_delete: :cascade

    create_table :order_results do |t|
      t.bigint  :order_run_id, null: false
      t.string  :query_text, limit: 2048
      t.json    :ordered_pair_ids
      t.integer :comparisons_used, null: false, default: 0
      t.integer :calls_used, null: false, default: 0
      t.integer :tokens_used, null: false, default: 0
      t.integer :cycles
      t.boolean :complete, null: false, default: true
      t.timestamps
    end
    add_index :order_results, :order_run_id
    add_foreign_key :order_results, :order_runs, on_delete: :cascade
  end
end
