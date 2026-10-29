# frozen_string_literal: true

# == Schema Information
#
# Table name: scorers
#
#  id                :integer          not null, primary key
#  code              :text(65535)
#  communal          :boolean          default(FALSE)
#  name              :string(255)
#  scale             :string(255)
#  scale_with_labels :text(65535)
#  show_scale_labels :boolean          default(FALSE)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  owner_id          :integer
#
# Indexes
#
#  index_scorers_owner_id  (owner_id)
#

require 'test_helper'

class ScorerTest < ActiveSupport::TestCase
  describe 'defaults' do
    test 'sets a default name to a scorer' do
      scorer = Scorer.new

      assert_not_nil  scorer.name
      assert_not      scorer.name.blank?
      assert_equal    scorer.name, "Scorer #{Scorer.count + 1}"
    end

    test 'handles empty string names' do
      scorer = Scorer.new name: ''

      assert_not_nil  scorer.name
      assert_not      scorer.name.blank?
      assert_equal    scorer.name, "Scorer #{Scorer.count + 1}"
    end
  end

  describe 'scale_list' do
    test 'accepts integers with stray spaces' do
      scorer = Scorer.new name: 'spaces', code: 'setScore(1);', scale_list: '0, 1, 2'

      assert_predicate scorer, :valid?
      assert_equal [ 0, 1, 2 ], scorer.scale
    end

    test 'reports a validation error instead of raising for non-integer values' do
      scorer = Scorer.new name: 'letters', code: 'setScore(1);', scale_list: 'a,b,c'

      assert_not scorer.valid?
      assert_predicate scorer.errors[:scale], :present?
      assert_equal 'a,b,c', scorer.scale_list
    end
  end

  describe 'emoji support' do
    test 'handles emoji in name' do
      scorer = Scorer.create name: '👍 👎 💩'

      assert_equal '👍 👎 💩', scorer.name
    end

    test 'handles emoji in code' do
      scorer = Scorer.create code: '// 👍 👎 💩'

      assert_equal '// 👍 👎 💩', scorer.code
    end

    test 'handles emoji in scale_with_labels' do
      scorer = Scorer.create scale_with_labels: { '1' => '👍' }

      assert_equal({ '1' => '👍' }, scorer.scale_with_labels)
    end
  end

  describe 'for_user' do
    it 'includes scorers where user is team owner' do
      scorers = Scorer.for_user(users(:random))
      assert_includes scorers, scorers(:shared_scorer)
    end

    it 'includes scorers connected to teams' do
      scorers = Scorer.for_user(users(:shared_team_member))
      assert_includes scorers, scorers(:random_scorer)
    end

    it 'includes scorers owned by user' do
      scorers = Scorer.for_user(users(:random))
      assert_includes scorers, scorers(:shared_scorer)
    end

    it 'includes communal scorers' do
      scorers = Scorer.for_user(users(:doug))
      assert_includes scorers, scorers(:communal_scorer)
    end

    it 'excludes other scorers' do
      scorers = Scorer.for_user(users(:doug))
      assert scorers.exclude?(scorers(:random_scorer))
    end
  end

  describe 'result diversity' do
    test 'a scorer that calls scoreByDiversity uses diversity, and measures that many results' do
      scorer = Scorer.new(name: 'ILD', code: "// ILD\nscoreByDiversity(5);")

      assert_predicate scorer, :uses_diversity?
      assert_equal 5, scorer.diversity_depth
    end

    test 'measures ten results unless the call says otherwise' do
      assert_equal 10, Scorer.new(name: 'ILD', code: 'scoreByDiversity();').diversity_depth
    end

    test 'other scorers do not use diversity' do
      assert_not Scorer.new(name: 'AP', code: 'setScore(avgRating());').uses_diversity?
      assert_not Scorer.new(name: 'None').uses_diversity?
    end

    test 'a pure diversity scorer does not read ratings; every other scorer does' do
      assert_not Scorer.new(name: 'ILD', code: 'scoreByDiversity(10);').uses_ratings?
      assert_predicate Scorer.new(name: 'AP', code: 'setScore(avgRating());'), :uses_ratings?
      assert_predicate Scorer.new(name: 'None'), :uses_ratings?
    end

    test 'scoreByExpectedDiversity is EILD: diversity scoring that reads ratings' do
      scorer = Scorer.new(name: 'EILD', code: 'scoreByExpectedDiversity(7);')

      assert_predicate scorer, :uses_diversity?
      assert_equal :eild, scorer.diversity_metric
      assert_predicate scorer, :uses_ratings?
      assert_equal 7, scorer.diversity_depth
    end

    test 'scoreByDiversity is ILD' do
      assert_equal :ild, Scorer.new(name: 'ILD', code: 'scoreByDiversity(10);').diversity_metric
    end

    test 'the default EILD@10 scorer is picked up from its file' do
      scorer = Scorer.new(name: 'EILD@10', code: Rails.root.join('db/scorers/eild@10.js').read)

      assert_predicate scorer, :uses_diversity?
      assert_equal :eild, scorer.diversity_metric
      assert_equal 10, scorer.diversity_depth
    end

    test 'a diversity scorer that also reads ratings keeps the rating UI' do
      code = "const best = topRatings(3);\nscoreByDiversity(10);"

      assert_predicate Scorer.new(name: 'EILD', code: code), :uses_ratings?
      assert_predicate Scorer.new(name: 'EILD', code: 'if (hasDocRating(0)) scoreByDiversity(5);'), :uses_ratings?
    end

    test 'the default ILD@10 scorer is seeded by the migration' do
      code = Rails.root.join('db/scorers/ild@10.js').read

      assert_predicate Scorer.new(name: 'ILD@10', code: code), :uses_diversity?
      assert_equal 10, Scorer.new(name: 'ILD@10', code: code).diversity_depth
    end
  end
end
