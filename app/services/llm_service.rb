# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'json'

class LlmService
  def initialize openai_key, _opts = {}
    @openai_key = openai_key
  end

  def perform_safe_judgement judgement
    perform_judgement(judgement)
  rescue RuntimeError => e
    case e.message
    when /401/
      raise # we can't do anything about this, so pass it up
    else
      judgement.explanation = "BOOM: #{e}"
      judgement.unrateable = true
    end
  end

  def perform_judgement judgement
    user_prompt = make_user_prompt judgement.query_doc_pair
    results = get_llm_response user_prompt, judgement.user.system_prompt

    judgement.rating = results[:judgment]
    judgement.explanation = results[:explanation]

    judgement
  end

  def make_user_prompt query_doc_pair
    document_fields = query_doc_pair.document_fields
    fields = document_fields.blank? ? '' : JSON.parse(document_fields).to_yaml

    user_prompt = <<~TEXT
      Query: #{query_doc_pair.query_text}

      doc1:
        #{fields}
    TEXT

    user_prompt
  end

  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/AbcSize
  def get_llm_response user_prompt, system_prompt
    llm_service_url = ENV['LLM_SERVICE_URL'] || 'https://api.openai.com'
    llm_model = ENV['LLM_MODEL'] || 'gpt-4o'
    llm_key = ENV['LLM_KEY'] || @openai_key
    llm_timeout = ENV['LLM_TIMEOUT'] || 30
    conn = Faraday.new(
      url: llm_service_url,
      request: {
        timeout: llm_timeout,
        open_timeout: llm_timeout
    }   ) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.request :retry, {
        max:                 3,
        interval:            2,
        interval_randomness: 0.5,
        backoff_factor:      2,
        retry_statuses:      [ 429 ],
      }
    end

    body = {
      model:           llm_model,
      response_format: { type: 'json_object' },
      messages:        [
        { role: 'system', content: system_prompt },
        { role: 'user', content: user_prompt }
      ],
    }

    response = conn.post('/v1/chat/completions') do |req|
      req.headers['Authorization'] = "Bearer #{llm_key}"
      req.headers['Content-Type'] = 'application/json'
      req.body = body
    end

    if response.success?
      begin
        chat_response = response.body
        if chat_response.is_a?(String)
          # in our tests the body is a String, but in real use it's already formatted as Json by Faraday
          chat_response = JSON.parse(chat_response)
        end

        content = chat_response['choices']&.first&.dig('message', 'content')

        parsed_content = JSON.parse(content)
        {
          explanation: parsed_content['explanation'],
          judgment:    parsed_content['judgment'],
        }
      rescue RuntimeError => e
        puts e
        raise "Error: Could not parse response from OpenAI: #{e} - #{response.env.response_body}"
      end
    else
      raise "Error: #{response.status} - #{response.body}"
    end
  end
  # rubocop:enable Metrics/MethodLength
  # rubocop:enable Metrics/AbcSize
end
