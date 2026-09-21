# frozen_string_literal: true

require 'test_helper'

module AiJudges
  class PromptControllerTest < ActionDispatch::IntegrationTest
    let(:user) { users(:random) }
    let(:ai_judge) { users(:judge_judy) }
    let(:team) { teams(:shared) }
    let(:book) { books(:james_bond_movies) }

    setup do
      login_user_for_integration_test user
    end

    describe 'get edit' do
      test 'should randomly pick qyer_doc_pair' do
        get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)
        assert_response :success

        assert assigns(:query_doc_pair)
      end

      test 'should get query_doc_pair from book if provided' do
        get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id), params: { book_id: book.id }
        assert_response :success

        assert assigns(:query_doc_pair)
        assert_includes(book.query_doc_pairs, assigns(:query_doc_pair))
      end
    end

    test 'flags instructions written for another kind of model, and offers the right default' do
      ai_judge.update!(system_prompt: LlmProviders::CHAT_SYSTEM_PROMPT,
                       judge_options: { llm_provider: 'typesafe_jev' })

      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)

      assert_response :success
      assert_select '#prompt-dialect-warning'
      assert_select '[data-use-default-prompt]', text: /Use TypeSafe Jev's default/
    end

    test 'says nothing when the instructions already belong to this provider' do
      ai_judge.update!(system_prompt: LlmProviders::JEV_SYSTEM_PROMPT,
                       judge_options: { llm_provider: 'typesafe_jev' })

      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)

      assert_response :success
      assert_select '#prompt-dialect-warning', count: 0
    end

    test 'says nothing about a prompt somebody wrote themselves' do
      ai_judge.update!(system_prompt: 'Only rate wine labels.',
                       judge_options: { llm_provider: 'typesafe_jev' })

      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)

      assert_response :success
      assert_select '#prompt-dialect-warning', count: 0
    end

    test 'shows the book scale as the criteria a typed model will be sent' do
      ai_judge.update!(judge_options: { llm_provider: 'typesafe_jev' })

      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id), params: { book_id: book.id }

      assert_response :success
      assert_select '#judging-criteria', text: /Criteria sent with the question/
      assert_select '#judging-criteria td', text: /Not Relevant/
      assert_select '#judging-criteria td', text: /level 1 . rating 1/
    end

    test 'shows a chat judge the scale as the prose its prompt will carry' do
      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id), params: { book_id: book.id }

      assert_response :success
      assert_select '#judging-criteria', text: /Rating scale added to the prompt/
      assert_select '#judging-criteria p', text: /0 \(labeled "Not Relevant"\)/
    end

    test 'shows no criteria when there is no book to take them from' do
      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)

      assert_response :success
      assert_select '#judging-criteria', count: 0
    end

    test 'still renders for a judge that has been removed from its team' do
      ai_judge.teams.destroy_all

      get edit_ai_judge_prompt_url(ai_judge_id: ai_judge.id)

      assert_response :success
      assert_select 'a', text: 'Edit Judge', count: 0
    end

    describe 'patch update' do
      setup { register_default_openai_stubs }

      test 'threads book context into the LLM call, so the system prompt reflects the book scale' do
        captured_system_prompt = nil
        stub_request(:post, 'https://api.openai.com/v1/chat/completions')
          .with(headers: { 'Authorization' => "Bearer #{OPENAI_VALID_KEY}" }) do |req|
            captured_system_prompt = JSON.parse(req.body)['messages'].find { |m| 'system' == m['role'] }['content']
            true
          end
          .to_return(status: 200, body: { choices: [ { message: { content: '{"judgment": 0, "explanation": "ok"}' } } ] }.to_json, headers: {})

        patch ai_judge_prompt_url(ai_judge_id: ai_judge.id),
              params: {
                book_id:        book.id,
                user:           { system_prompt: ai_judge.system_prompt },
                query_doc_pair: { query_text: 'what year was this released?', doc_id: 'goldeneye', document_fields: '{}' },
              }

        assert_response :success
        assert_includes captured_system_prompt, "This book's rating scale is:"
      end

      test 'a rating this book would reject is shown as unrateable, not as a usable rating' do
        # the book's scale is 0,1 and the judge answers 3
        stub_request(:post, 'https://api.openai.com/v1/chat/completions')
          .with(headers: { 'Authorization' => "Bearer #{OPENAI_VALID_KEY}" })
          .to_return(status: 200,
                     body:   { choices: [ { message: { content: '{"judgment": 3, "explanation": "Perfect"}' } } ] }.to_json, headers: {})

        assert_no_difference 'Judgement.count' do
          patch ai_judge_prompt_url(ai_judge_id: ai_judge.id),
                params: {
                  book_id:        book.id,
                  user:           { system_prompt: ai_judge.system_prompt },
                  query_doc_pair: { query_text: 'what year was this released?', doc_id: 'goldeneye',
                                    document_fields: '{}' },
                }
        end

        assert_response :success
        assert_predicate assigns(:judgement), :unrateable
        assert_nil assigns(:judgement).rating
        assert_match(/Unrateable/, response.body)
        assert_match(/outside this book&#39;s scale/, response.body)
      end

      test 'a rating on the book scale is still shown as the rating' do
        stub_request(:post, 'https://api.openai.com/v1/chat/completions')
          .with(headers: { 'Authorization' => "Bearer #{OPENAI_VALID_KEY}" })
          .to_return(status: 200,
                     body:   { choices: [ { message: { content: '{"judgment": 1, "explanation": "Relevant"}' } } ] }.to_json, headers: {})

        patch ai_judge_prompt_url(ai_judge_id: ai_judge.id),
              params: {
                book_id:        book.id,
                user:           { system_prompt: ai_judge.system_prompt },
                query_doc_pair: { query_text: 'what year was this released?', doc_id: 'goldeneye',
                                  document_fields: '{}' },
              }

        assert_response :success
        assert_not assigns(:judgement).unrateable
        assert_in_delta(1.0, assigns(:judgement).rating)
        assert_no_match(/Unrateable/, response.body)
      end
    end
  end
end
