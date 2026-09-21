# frozen_string_literal: true

# The registry of LLM vendors AI Judges can use.
#
# Single source of truth for the provider dropdown and the preset/help panel in
# app/views/ai_judges/_form.html.erb. Adding a provider means adding an entry here.
#
# Built on each call rather than frozen into a constant because one entry (ollama)
# depends on Rails.configuration, which tests and deployments override.
#
# rubocop:disable Metrics/ModuleLength -- a registry is long by nature; same reason
# Metrics/ClassLength is off repo-wide.
module LlmProviders
  class << self
    def all
      [
        openai, azure_openai, azure_ai_foundry, azure_ai_foundry_serverless,
        azure_ai_foundry_anthropic, anthropic, google_gemini, ollama, typesafe_jev
      ]
    end

    def [] key
      all.find { |provider| provider.key == key.to_s }
    end

    def keys
      all.map(&:key)
    end

    def each(&)
      all.each(&)
    end

    # [[label, key], ...] for options_for_select
    def select_options
      all.map(&:to_select_option)
    end

    # Providers listed in the form that Quepid cannot judge with yet.
    def coming_soon
      all.select(&:coming_soon?)
    end

    def presets
      all.index_by(&:key).transform_values(&:to_preset)
    end

    # Safe to interpolate into a <script> tag: ActiveSupport escapes HTML entities
    # (including any "</script>") as \u-escapes when serializing to JSON.
    def presets_json
      presets.to_json
    end

    private

    def openai
      LlmProvider.new(
        key:                 'openai',
        label:               'OpenAI',
        default_service_url: 'https://api.openai.com',
        default_model:       'gpt-4o',
        help_html:           '<strong>OpenAI</strong> &mdash; Direct API access.<br>' \
                             '<b>URL:</b> <code>https://api.openai.com</code><br>' \
                             '<b>Model:</b> e.g. <code>gpt-4o</code>, <code>gpt-4.1</code><br>' \
                             '<b>Key:</b> Your OpenAI API key (starts with <code>sk-</code>)<br>' \
                             '<b>API Version:</b> Leave blank'
      )
    end

    def azure_openai
      LlmProvider.new(
        key:                 'azure_openai',
        auth_style:          :api_key,
        label:               'Azure OpenAI',
        default_service_url: 'https://RESOURCE.openai.azure.com',
        default_model:       'gpt-4.1',
        help_html:           '<strong>Azure OpenAI</strong> &mdash; OpenAI models hosted on Azure.<br>' \
                             '<b>URL:</b> <code>https://YOUR-RESOURCE.openai.azure.com</code><br>' \
                             '<b>Model:</b> Your deployment name, e.g. <code>gpt-4.1</code>, ' \
                             '<code>gpt-5.1</code><br>' \
                             '<b>Key:</b> Azure resource API key<br>' \
                             '<b>API Version:</b> Set to use deployment-based routing ' \
                             '(e.g. <code>2024-12-01-preview</code>), or leave blank for ' \
                             '<code>/openai/v1/</code> path'
      )
    end

    def azure_ai_foundry
      LlmProvider.new(
        key:                 'azure_ai_foundry',
        auth_style:          :api_key,
        label:               'Azure AI Foundry',
        default_service_url: 'https://RESOURCE.services.ai.azure.com',
        default_api_version: '2025-01-01-preview',
        default_model:       'gpt-4o',
        help_html:           '<strong>Azure AI Foundry</strong> &mdash; Unified Azure AI endpoint.<br>' \
                             '<b>URL:</b> <code>https://YOUR-RESOURCE.services.ai.azure.com</code><br>' \
                             '<b>Model:</b> Model name, e.g. <code>gpt-4o</code><br>' \
                             '<b>Key:</b> Azure AI services key<br>' \
                             '<b>API Version:</b> Defaults to <code>2025-01-01-preview</code>'
      )
    end

    def azure_ai_foundry_serverless
      LlmProvider.new(
        key:                 'azure_ai_foundry_serverless',
        auth_style:          :api_key,
        label:               'Azure AI Foundry (Serverless)',
        default_service_url: 'https://MODEL-NAME.REGION.models.ai.azure.com',
        default_model:       '',
        help_html:           '<strong>Azure AI Foundry (Serverless)</strong> &mdash; ' \
                             'Models-as-a-Service pay-per-token endpoint.<br>' \
                             '<b>URL:</b> <code>https://MODEL-NAME.REGION.models.ai.azure.com</code><br>' \
                             '<b>Model:</b> Model name from the deployment<br>' \
                             '<b>Key:</b> Serverless endpoint key<br>' \
                             '<b>API Version:</b> Leave blank'
      )
    end

    def azure_ai_foundry_anthropic
      LlmProvider.new(
        key:                 'azure_ai_foundry_anthropic',
        adapter:             'LlmJudgeAdapters::Anthropic',
        auth_style:          :x_api_key,
        label:               'Azure AI Foundry (Anthropic)',
        default_service_url: 'https://RESOURCE.services.ai.azure.com/anthropic',
        default_model:       'claude-3-5-haiku-20241022',
        help_html:           '<strong>Azure AI Foundry (Anthropic)</strong> &mdash; Claude models via ' \
                             'Azure using the native Anthropic Messages API.<br>' \
                             '<b>URL:</b> <code>https://YOUR-RESOURCE.services.ai.azure.com/anthropic</code><br>' \
                             '<b>Model:</b> e.g. <code>claude-3-5-haiku-20241022</code><br>' \
                             '<b>Key:</b> Azure AI services key (sent as <code>x-api-key</code> header)<br>' \
                             '<b>API Version:</b> Leave blank (the <code>anthropic-version</code> header ' \
                             'is set automatically)'
      )
    end

    def anthropic
      LlmProvider.new(
        key:                 'anthropic',
        adapter:             'LlmJudgeAdapters::Anthropic',
        auth_style:          :x_api_key,
        label:               'Anthropic',
        default_service_url: 'https://api.anthropic.com',
        default_model:       'claude-sonnet-4-5-20250514',
        help_html:           '<strong>Anthropic</strong> &mdash; Direct Anthropic API access.<br>' \
                             '<b>URL:</b> <code>https://api.anthropic.com</code><br>' \
                             '<b>Model:</b> e.g. <code>claude-opus-4-6</code>, ' \
                             '<code>claude-sonnet-4-5-20250514</code><br>' \
                             '<b>Key:</b> Your Anthropic API key (sent as <code>x-api-key</code> header)<br>' \
                             '<b>API Version:</b> Leave blank'
      )
    end

    def google_gemini
      LlmProvider.new(
        key:                 'google_gemini',
        label:               'Google Gemini',
        default_service_url: 'https://generativelanguage.googleapis.com/v1beta/openai',
        default_model:       'gemini-2.0-flash',
        help_html:           '<strong>Google Gemini</strong> &mdash; Uses the OpenAI-compatible endpoint.<br>' \
                             '<b>URL:</b> <code>https://generativelanguage.googleapis.com/v1beta/openai' \
                             '</code><br>' \
                             '<b>Model:</b> e.g. <code>gemini-2.0-flash</code><br>' \
                             '<b>Key:</b> Your Google AI API key<br>' \
                             '<b>API Version:</b> Leave blank'
      )
    end

    # Placeholder entry: Jev is a typed "System One" model, not a chat model, so it needs
    # its own adapter before a judging run can use it (docs/adr/0001, docs/todo/jev_llm_judge.md).
    # It is listed now so teams can see what it will need -- an API key -- and get one;
    # AiJudgesController refuses to save a judge pointed at it until the adapter lands.
    def typesafe_jev
      LlmProvider.new(
        key:                 'typesafe_jev',
        adapter:             'LlmJudgeAdapters::Jev',
        label:               'TypeSafe Jev',
        default_service_url: 'https://api.typesafe.ai',
        default_model:       'jev-latest',
        read_only_fields:    %w[llm_service_url llm_model llm_api_version],
        help_html:           '<strong>TypeSafe Jev</strong> &mdash; A typed evaluation model rather than a ' \
                             'chat model: it answers with a rating, a probability distribution and a ' \
                             'confidence, and cannot return a rating outside your scale.<br>' \
                             '<b>URL:</b> <code>https://api.typesafe.ai</code> (fixed)<br>' \
                             '<b>Model:</b> <code>jev-latest</code> (fixed)<br>' \
                             '<b>Key:</b> Your TypeSafe API key from ' \
                             '<a href="https://console.typesafe.ai/keys" target="_blank" rel="noopener">' \
                             'console.typesafe.ai/keys</a><br>' \
                             '<b>API Version:</b> Not used<br>' \
                             'The book\'s rating scale and labels become the judging criteria, so a Jev ' \
                             'judge must be run from a book, and its system prompt only says what to weigh ' \
                             '&mdash; not the scale or an output format. It writes no prose, so the ' \
                             'explanation Quepid stores is built from the score, confidence and ' \
                             'distribution. Text only &mdash; document images are ignored. Optional: add ' \
                             '<code>jev_min_confidence</code> (e.g. <code>0.4</code>) on the JSON tab to ' \
                             'mark answers below that confidence unrateable.'
      )
    end

    def ollama
      url = Rails.configuration.ollama_service_url

      LlmProvider.new(
        key:                 'ollama',
        label:               'Ollama',
        default_service_url: url,
        default_model:       'qwen3:0.6b',
        help_html:           '<strong>Ollama</strong> &mdash; Local models via the Ollama container.<br>' \
                             "<b>URL:</b> <code>#{ERB::Util.html_escape(url)}</code><br>" \
                             '<b>Model:</b> e.g. <code>qwen3:0.6b</code>, <code>llama3</code><br>' \
                             '<b>Key:</b> Any placeholder value (e.g. <code>abc123</code>)<br>' \
                             '<b>API Version:</b> Leave blank'
      )
    end
  end
end
# rubocop:enable Metrics/ModuleLength
