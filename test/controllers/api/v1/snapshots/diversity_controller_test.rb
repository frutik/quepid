# frozen_string_literal: true

require 'test_helper'

module Api
  module V1
    module Snapshots
      class DiversityControllerTest < ActionController::TestCase
        include ActiveJob::TestHelper

        let(:user)     { users(:random) }
        let(:acase)    { cases(:shared_with_team) }
        let(:embedder) { embedders(:openai_small) }
        let(:snapshot) { acase.snapshots.create!(name: 'diverse') }

        before do
          @controller = Api::V1::Snapshots::DiversityController.new
          login_user user
          acase.update!(embedder: embedder)
        end

        test 'show reports the value, how it was made and per-query values' do
          query = acase.queries.create!(query_text: 'star wars')
          snapshot.snapshot_queries.create!(query: query, diversity: 0.4)
          snapshot.update!(diversity: 0.4, diversity_meta: { 'status' => 'done', 'fingerprint' => embedder.document_fingerprint,
                                                             'depth' => 10, 'title_field' => 'name' })

          get :show, params: { case_id: acase.id, snapshot_id: snapshot.id }

          assert_response :ok
          body = response.parsed_body

          assert_in_delta 0.4, body['diversity']
          assert_equal 'name', body['diversity_meta']['title_field']
          assert_not body['stale']
          assert_not body['running']
          assert_equal [ { 'query_id' => query.id, 'diversity' => 0.4 } ], body['queries']
        end

        test 'show names the field a run would embed' do
          snapshot.update!(try: acase.tries.create!(field_spec: 'id:id title:name'))

          get :show, params: { case_id: acase.id, snapshot_id: snapshot.id }

          assert_equal 'name', response.parsed_body['title_field']
          assert_not response.parsed_body['title_is_id']
        end

        test 'show says when the title is the id' do
          snapshot.update!(try: acase.tries.create!(field_spec: 'id:id title:id *'))

          get :show, params: { case_id: acase.id, snapshot_id: snapshot.id }

          assert response.parsed_body['title_is_id']
        end

        test 'show flags a value made with another embedder setting as stale' do
          snapshot.update!(diversity: 0.4, diversity_meta: { 'status' => 'done', 'fingerprint' => 'something-else', 'depth' => 10 })

          get :show, params: { case_id: acase.id, snapshot_id: snapshot.id }

          assert response.parsed_body['stale']
        end

        test 'show is null before anything was computed' do
          get :show, params: { case_id: acase.id, snapshot_id: snapshot.id }

          assert_response :ok
          assert_nil response.parsed_body['diversity']
          assert_nil response.parsed_body['diversity_meta']
        end

        test 'create enqueues the job' do
          assert_enqueued_with(job: ComputeSnapshotDiversityJob, args: [ snapshot, { force: false } ]) do
            post :create, params: { case_id: acase.id, snapshot_id: snapshot.id }
          end

          assert_response :accepted
        end

        test 'create passes force on' do
          assert_enqueued_with(job: ComputeSnapshotDiversityJob, args: [ snapshot, { force: true } ]) do
            post :create, params: { case_id: acase.id, snapshot_id: snapshot.id, force: 'true' }
          end
        end

        test 'create needs an embedder on the case' do
          acase.update!(embedder: nil)

          assert_no_enqueued_jobs do
            post :create, params: { case_id: acase.id, snapshot_id: snapshot.id }
          end

          assert_response :unprocessable_content
        end

        test 'create refuses when the user cannot see the case\'s embedder' do
          acase.update!(embedder: embedders(:private_ollama))

          assert_no_enqueued_jobs do
            post :create, params: { case_id: acase.id, snapshot_id: snapshot.id }
          end

          assert_response :forbidden
        end

        test 'create is not available for a case the user is not involved with' do
          other = cases(:one)

          assert_no_enqueued_jobs do
            post :create, params: { case_id: other.id, snapshot_id: other.snapshots.create!(name: 'x').id }
          end

          assert_response :not_found
        end

        test 'a snapshot of another case is not found' do
          other_snapshot = cases(:one).snapshots.create!(name: 'other')

          get :show, params: { case_id: acase.id, snapshot_id: other_snapshot.id }

          assert_response :not_found
        end
      end
    end
  end
end
