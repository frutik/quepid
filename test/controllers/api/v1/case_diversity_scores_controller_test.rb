# frozen_string_literal: true

require 'test_helper'

module Api
  module V1
    class CaseDiversityScoresControllerTest < ActionController::TestCase
      URL = 'https://api.openai.com/v1/embeddings'

      let(:user)     { users(:random) }
      let(:acase)    { cases(:shared_with_team) }
      let(:embedder) { embedders(:openai_small) }

      before do
        @controller = Api::V1::CaseDiversityScoresController.new
        login_user user
        acase.update!(embedder: embedder)
      end

      def respond_with_orthogonal_vectors
        stub_request(:post, URL).to_return do |request|
          inputs = JSON.parse(request.body)['input']
          { status: 200, headers: { 'Content-Type' => 'application/json' },
            body: { data: inputs.each_index.map { |i| { index: i, embedding: Array.new(512) { |n| n == i ? 1.0 : 0.0 } } } }.to_json }
        end
      end

      def titles
        [ { id: 'a', title: 'Star Wars' }, { id: 'b', title: 'Casablanca' }, { id: 'c', title: 'Alien' } ]
      end

      test 'scores the results by their diversity' do
        respond_with_orthogonal_vectors

        post :create, params: { case_id: acase.id, docs: titles, count: 3 }

        assert_response :ok
        assert_in_delta 1.0, response.parsed_body['score'], 1.0e-6
        assert_equal 3, response.parsed_body['embedded']
      end

      test 'only measures the first count results' do
        respond_with_orthogonal_vectors

        post :create, params: { case_id: acase.id, docs: titles, count: 2 }

        assert_requested(:post, URL) { |request| [ 'Star Wars', 'Casablanca' ] == JSON.parse(request.body)['input'] }
      end

      test 'uses the case\'s diversity embedder when it has one' do
        other = Embedder.create!(name: 'Other', provider: 'openai', service_url: 'https://api.openai.com',
                                 model: 'text-embedding-3-large', api_key: 'sk-other', owner: user)
        acase.update!(diversity_embedder: other)
        respond_with_orthogonal_vectors

        post :create, params: { case_id: acase.id, docs: titles }

        assert_requested(:post, URL) { |request| 'text-embedding-3-large' == JSON.parse(request.body)['model'] }
      end

      test 'has no score for a single result' do
        respond_with_orthogonal_vectors

        post :create, params: { case_id: acase.id, docs: [ titles.first ] }

        assert_response :ok
        assert_nil response.parsed_body['score']
      end

      test 'needs an embedder' do
        acase.update!(embedder: nil)

        post :create, params: { case_id: acase.id, docs: titles }

        assert_response :unprocessable_content
      end

      test 'refuses an embedder the user cannot see' do
        acase.update!(embedder: embedders(:private_ollama))

        post :create, params: { case_id: acase.id, docs: titles }

        assert_response :forbidden
        assert_not_requested :post, URL
      end

      test 'passes on a provider error' do
        stub_request(:post, URL).to_return(status: 401, body: { error: { message: 'bad key' } }.to_json,
                                           headers: { 'Content-Type' => 'application/json' })

        post :create, params: { case_id: acase.id, docs: titles }

        assert_response :bad_gateway
        assert_match(/bad key/, response.parsed_body['error'])
      end

      test 'is not available for a case the user is not involved with' do
        post :create, params: { case_id: cases(:one).id, docs: titles }

        assert_response :not_found
      end
    end
  end
end
