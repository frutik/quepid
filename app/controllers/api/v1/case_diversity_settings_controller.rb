# frozen_string_literal: true

module Api
  module V1
    # How many top results per query diversity is measured over. Stored on the case, not in its
    # options: those are sent to the search engine with every search.
    # @tags cases > embedders
    class CaseDiversitySettingsController < Api::ApiController
      before_action :set_case
      before_action :require_case_involvement

      # @summary Set the diversity depth
      # @parameter diversity_depth(query) [Integer] Top results per query, 2 to 100; blank for the default (10).
      def update
        if @case.update(diversity_depth: params[:diversity_depth].presence)
          render :show
        else
          render json: { error: @case.errors.full_messages.to_sentence }, status: :unprocessable_content
        end
      end

      private

      def require_case_involvement
        return if current_user.cases_involved_with.exists?(id: @case.id)

        render json: { error: 'Case not found' }, status: :not_found
      end
    end
  end
end
