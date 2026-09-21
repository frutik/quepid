# frozen_string_literal: true

require 'test_helper'

class AiJudgesControllerTest < ActionDispatch::IntegrationTest
  let(:user) { users(:random) }
  let(:ai_judge) { users(:judge_judy) }
  let(:team) { teams(:shared) }

  setup do
    login_user_for_integration_test user
  end

  test 'should get new' do
    get new_team_ai_judge_url(team_id: team.id)
    assert_response :success
  end

  test 'new renders the provider dropdown and presets from the LlmProviders registry' do
    get new_team_ai_judge_url(team_id: team.id)

    LlmProviders.each do |provider|
      assert_select 'select#judge_options_llm_provider option[value=?]', provider.key, text: provider.label
    end
    presets_json = response.body[/const PROVIDER_PRESETS = (\{.*?\});$/m, 1]

    assert_not_nil presets_json, 'PROVIDER_PRESETS was not rendered into the form'
    assert_equal LlmProviders.presets.deep_stringify_keys, JSON.parse(presets_json)
  end

  test 'should create ai_judge' do
    assert_difference('User.count') do
      post team_ai_judges_url(team_id: team.id),
           params: { user: {
             name: ai_judge.name, llm_key: ai_judge.llm_key, system_prompt: ai_judge.system_prompt
           } }
    end
    assert_redirected_to team_url(id: team.id)
  end

  test 'new renders the banner element placeholder providers would use' do
    get new_team_ai_judge_url(team_id: team.id)

    assert_select 'div#provider-notice'
    assert_select 'select#judge_options_llm_provider option[value=?]', 'typesafe_jev'
  end

  # The refusal path (a provider carrying a coming-soon notice cannot be saved)
  # has no provider to exercise it now that Jev is real; the rule itself is
  # tested as LlmProvider#coming_soon? in test/models/llm_providers_test.rb.
  test 'saves a judge pointed at a provider that is available' do
    assert_difference('User.count', 1) do
      post team_ai_judges_url(team_id: team.id),
           params: { user: {
             name:          'Jev Judge',
             llm_key:       'abc123',
             system_prompt: 'Judge this',
             judge_options: { llm_provider: 'typesafe_jev' },
           } }
    end

    assert_redirected_to team_url(id: team.id)
    assert_equal 'typesafe_jev', User.order(:id).last.judge_options[:llm_provider]
  end

  test 'should destroy ai_judge' do
    assert_difference('User.count', -1) do
      delete team_ai_judge_url(team_id: team.id, id: ai_judge.id)
    end

    assert_redirected_to team_url(id: team.id)
  end
end
