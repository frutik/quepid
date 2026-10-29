# frozen_string_literal: true

# Adds the communal ILD@10 scorer (result diversity). Like the other default scorers it is
# created by db/seeds.rb on a fresh install; this brings existing installs up to date.
class AddIldScorer < ActiveRecord::Migration[8.1]
  def up
    scorer = Scorer.find_or_initialize_by(name: 'ILD@10')
    scorer.update!(
      # The rating scale is the case's rating scale, so keep it the same as the other defaults:
      # choosing ILD@10 must not change how documents are rated.
      scale:             (0..3).to_a,
      scale_with_labels: { '0': 'Poor', '1': 'Fair', '2': 'Good', '3': 'Perfect' },
      show_scale_labels: true,
      code:              File.read(Rails.root.join('db/scorers/ild@10.js')),
      communal:          true
    )
  end

  def down
    Scorer.where(name: 'ILD@10', communal: true).destroy_all
  end
end
