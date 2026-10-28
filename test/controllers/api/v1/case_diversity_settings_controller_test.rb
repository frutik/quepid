# frozen_string_literal: true

require 'test_helper'

module Api
  module V1
    class CaseDiversitySettingsControllerTest < ActionController::TestCase
      let(:user)  { users(:random) }
      let(:acase) { cases(:shared_with_team) }

      before do
        @controller = Api::V1::CaseDiversitySettingsController.new
        login_user user
      end

      test 'update sets the depth' do
        put :update, params: { case_id: acase.id, diversity_depth: 25 }

        assert_response :ok
        assert_equal 25, acase.reload.diversity_depth
        assert_equal 25, response.parsed_body['effective_diversity_depth']
      end

      test 'a blank depth goes back to the default' do
        acase.update!(diversity_depth: 25)

        put :update, params: { case_id: acase.id, diversity_depth: '' }

        assert_response :ok
        assert_nil acase.reload.diversity_depth
        assert_equal 10, response.parsed_body['effective_diversity_depth']
      end

      test 'rejects a depth outside 2 to 100' do
        put :update, params: { case_id: acase.id, diversity_depth: 1 }

        assert_response :unprocessable_content
        assert_nil acase.reload.diversity_depth
      end

      test 'refuses a case the user is not involved with' do
        put :update, params: { case_id: cases(:one).id, diversity_depth: 5 }

        assert_response :not_found
      end
    end
  end
end
