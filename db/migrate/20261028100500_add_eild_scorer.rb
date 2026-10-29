# frozen_string_literal: true

# Adds the communal EILD@10 scorer (rank- and relevance-aware result diversity), next to ILD@10.
# Like the other default scorers it is created by db/seeds.rb on a fresh install; this brings
# existing installs up to date.
class AddEildScorer < ActiveRecord::Migration[8.1]
  def up
    scorer = Scorer.find_or_initialize_by(name: 'EILD@10')
    scorer.update!(
      # The rating scale is the case's rating scale, and EILD reads ratings: the usual 0 to 3.
      scale:             (0..3).to_a,
      scale_with_labels: { '0': 'Poor', '1': 'Fair', '2': 'Good', '3': 'Perfect' },
      show_scale_labels: true,
      code:              File.read(Rails.root.join('db/scorers/eild@10.js')),
      communal:          true
    )
  end

  def down
    Scorer.where(name: 'EILD@10', communal: true).destroy_all
  end
end
