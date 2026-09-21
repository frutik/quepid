# frozen_string_literal: true

class AiJudgesController < ApplicationController
  before_action :set_team
  before_action :set_ai_judge, only: [ :show, :edit, :update, :destroy ]

  # Kept as a constant because tests and other callers refer to it; the text
  # itself now lives with the providers that use it (LlmProviders), since what
  # a judge should be told depends on the dialect it speaks.
  DEFAULT_SYSTEM_PROMPT = LlmProviders::CHAT_SYSTEM_PROMPT

  def show
    render 'edit'
  end

  def new
    @ai_judge = User.new
    @ai_judge.system_prompt = LlmProviders['openai'].default_system_prompt
    @ai_judge.judge_options = {
      llm_provider:    'openai',
      llm_service_url: 'https://api.openai.com',
      llm_model:       'gpt-4o',
      llm_timeout:     30,
      llm_api_version: '',
    }
  end

  def edit; end

  def create
    @ai_judge = User.new(ai_judge_params)

    if unavailable_provider?(@ai_judge) || !@ai_judge.save
      render :new
    else
      @team.members << @ai_judge
      @team.save
      redirect_to team_path(@team)
    end
  end

  def update
    @ai_judge.assign_attributes(ai_judge_params)

    if unavailable_provider?(@ai_judge) || !@ai_judge.save
      render 'edit'
    else
      redirect_to team_path(@team)
    end
  end

  def destroy
    @ai_judge.destroy
    redirect_to team_path(@team) # , notice: 'AI Judge was successfully removed.'
  end

  private

  # A provider can appear in the form before Quepid can actually judge with it, so teams
  # can see what it will need and get a key ready (LlmProviders#coming_soon). Selecting
  # one is fine; saving a judge that would fail on its first run is not.
  def unavailable_provider? ai_judge
    provider = LlmProviders[ai_judge.judge_options[:llm_provider]]
    return false unless provider&.coming_soon?

    ai_judge.errors.add(:base, "#{provider.label} is not available yet, so an AI Judge cannot use it.")
    true
  end

  def set_team
    @team = current_user.teams.find(params.expect(:team_id))
  end

  def set_ai_judge
    @ai_judge = @team.members.only_ai_judges.find(params.expect(:id))
  end

  def ai_judge_params
    params_to_return = params.expect(user: [ :name, :llm_key, :system_prompt, :options, { judge_options: {} } ])
    params_to_return[:options] = JSON.parse(params_to_return[:options]) if params_to_return[:options]

    params_to_return
  end
end
