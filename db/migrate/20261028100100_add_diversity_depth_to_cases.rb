# frozen_string_literal: true

class AddDiversityDepthToCases < ActiveRecord::Migration[8.1]
  def change
    # How many top results per query diversity is measured over; NULL means the default.
    # A column of its own: cases.options is sent to the search engine as qOption.
    add_column :cases, :diversity_depth, :integer
  end
end
