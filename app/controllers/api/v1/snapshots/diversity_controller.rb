# frozen_string_literal: true

module Api
  module V1
    module Snapshots
      # How different the top results of each query in a snapshot are from one another, computed
      # by ComputeSnapshotDiversityJob with the case's embedder. Computing spends the embedder
      # owner's API key, so -- like assigning an embedder -- it needs a case the user is involved
      # with and an embedder they can see.
      # @tags cases > snapshots
      class DiversityController < Api::ApiController
        before_action :set_case
        before_action :set_snapshot
        before_action :require_case_involvement, only: :create

        # The snapshot's diversity, how it was made, whether it is stale and whether a run is
        # queued or under way -- the case page polls this.
        def show
          render_state
        end

        # @summary Compute the snapshot's diversity
        # > Embeds the titles of its top results, which spends the embedder's API key.
        # @parameter force(query) [Boolean] Embed every document again, not just the ones without a current vector.
        def create
          embedder = @case.effective_diversity_embedder
          if embedder.nil?
            render json: { error: 'This case has no embedder' }, status: :unprocessable_content
            return
          end

          unless current_user.embedders_involved_with.exists?(id: embedder.id)
            render json: { error: 'You cannot use this case\'s embedder' }, status: :forbidden
            return
          end

          ComputeSnapshotDiversityJob.enqueue_for(@snapshot, force: deserialize_bool_param(params[:force]))
          render_state(status: :accepted)
        end

        private

        def set_snapshot
          @snapshot = @case.snapshots.find(params.expect(:snapshot_id))
        end

        def require_case_involvement
          return if current_user.cases_involved_with.exists?(id: @case.id)

          render json: { error: 'Case not found' }, status: :not_found
        end

        def render_state status: :ok
          @running = ComputeSnapshotDiversityJob.running?(@snapshot)
          @field_spec = FieldSpec.new((@snapshot.try || @case.tries.first)&.field_spec)
          @snapshot_queries = @snapshot.snapshot_queries.order(:id)
          render :show, status: status
        end
      end
    end
  end
end
