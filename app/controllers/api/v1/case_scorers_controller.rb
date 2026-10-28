# frozen_string_literal: true

module Api
  module V1
    class CaseScorersController < Api::ApiController
      before_action :set_case

      def index
        @default           = @case.scorer
        @communal_scorers  = Scorer.communal

        respond_with @communal_scorers, @default
      end

      def update
        scorer_id = params[:id]

        # rubocop:disable-next Style/IfUnlessModifier
        if scorer_removed?
          scorer_id = nil
        end

        attributes = { scorer_id: scorer_id }
        if params.key?(:diversity_embedder_id)
          embedder = diversity_embedder
          return if performed?

          attributes[:diversity_embedder_id] = embedder&.id
        end

        if @case.update attributes
          Analytics::Tracker.track_case_updated_event current_user, @case
          respond_with @case
        else
          render json: @case.errors, status: :bad_request
        end
      rescue ActiveRecord::InvalidForeignKey
        render json: { error: 'Invalid id' }, status: :bad_request
      end

      private

      # The embedder the ILD scorer uses on this case, or nil to use the case's own (blank or 0).
      # Like any embedder it spends its owner's API key, so it has to be one the user can see, on
      # a case they are involved with -- set_case also lets through public cases anyone can view.
      def diversity_embedder
        unless current_user.cases_involved_with.exists?(id: @case.id)
          render json: { error: 'Case not found' }, status: :not_found
          return nil
        end
        return nil if [ nil, '', 0, '0' ].include?(params[:diversity_embedder_id])

        embedder = current_user.embedders_involved_with.not_archived.find_by(id: params[:diversity_embedder_id])
        render json: { error: 'Embedder not found' }, status: :not_found if embedder.nil?
        embedder
      end

      def scorer_removed?
        [ 0, '0' ].include?(params[:id])
      end
    end
  end
end
