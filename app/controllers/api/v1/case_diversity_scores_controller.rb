# frozen_string_literal: true

module Api
  module V1
    # The ILD scorer's score for one query's results, worked out here because the browser can't
    # embed text: it posts the titles of the top results and gets back how different they are
    # from one another. Vectors are cached per case (DocumentEmbedding), so a result seen before
    # costs no API call. It spends the embedder owner's API key, so -- like assigning an
    # embedder -- it needs a case the user is involved with and an embedder they can see.
    # @tags cases > embedders
    class CaseDiversityScoresController < Api::ApiController
      MAX_DOCS = 100
      # A search page can't wait long for embeddings.
      REQUEST_TIMEOUT = 20

      before_action :set_case
      before_action :require_case_involvement

      # @summary Score a query's results by their diversity
      # @parameter docs(body) [Array<Hash>] The top results in rank order, each { id, title } and,
      #   for EILD, relevance (0 to 1).
      # @parameter metric(body) [String] ild (default) or eild, which weights by rank and relevance.
      # @parameter count(body) [Integer] How many of them to measure; defaults to all, at most 100.
      def create
        embedder = @case.effective_diversity_embedder
        return render_error('This case has no embedder to measure diversity with', :unprocessable_content) if embedder.nil?
        return render_error('You cannot use this case\'s embedder', :forbidden) unless current_user.embedders_involved_with.exists?(id: embedder.id)

        result = ResultDiversity.new(@case, embedder, timeout: REQUEST_TIMEOUT).score(docs, metric: metric)
        return render_error(result.errors.first, :bad_gateway) if result.errors.any?

        render json: { score: result.value, embedded: result.embedded }
      end

      private

      # [{ id:, text:, relevance: }] for the first `count` results; a result without a title is
      # left out later.
      def docs
        permitted = params.permit(docs: [ :id, :title, :relevance ])[:docs] || []
        count = params[:count].presence&.to_i || MAX_DOCS
        permitted.first(count.clamp(1, MAX_DOCS)).map do |doc|
          { id: doc[:id].to_s, text: doc[:title].presence, relevance: doc[:relevance].to_f.clamp(0.0, 1.0) }
        end
      end

      def metric
        'eild' == params[:metric] ? :eild : :ild
      end

      def render_error message, status
        render json: { error: message }, status: status
      end

      def require_case_involvement
        return if current_user.cases_involved_with.exists?(id: @case.id)

        render_error('Case not found', :not_found)
      end
    end
  end
end
