# frozen_string_literal: true

# Intra-list diversity of a snapshot's results (see ComputeSnapshotDiversityJob). A metric of
# its own next to the score, not a scorer.
class AddDiversityToSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :snapshot_queries, :diversity, :float
    add_column :snapshots, :diversity, :float
    # How the value was made, so two snapshots can be told comparable or not.
    add_column :snapshots, :diversity_meta, :json
  end
end
