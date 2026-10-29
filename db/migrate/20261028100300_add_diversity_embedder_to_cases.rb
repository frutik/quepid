# frozen_string_literal: true

class AddDiversityEmbedderToCases < ActiveRecord::Migration[8.1]
  def change
    # The embedder the ILD scorer uses on this case's result documents; NULL means the case's
    # own embedder. Set where the scorer is picked, not on the (shared) scorer itself.
    add_column :cases, :diversity_embedder_id, :bigint
    add_index :cases, :diversity_embedder_id
  end
end
