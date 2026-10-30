# frozen_string_literal: true

require 'digest'

# Answers "which of these two documents is more relevant to the query?" for a
# ranking judge, asking the provider only when the table has not already been
# told. The table (PreferenceComparison) is the cache: nothing is kept in the
# process, so a re-run, a second strategy or another worker reads what an
# earlier one paid for (docs/adr/0005 D2).
#
#   oracle = PairwiseOracle.new(judge: judge)
#   oracle.compare(pair_x, pair_y)   # => :a, :b or :tie, for pair_x as a and pair_y as b
#
# Both documents must be pairs of the same query. Calls cost what the provider
# charges and are counted in #calls; a cache hit is free.
class PairwiseOracle
  class Unreadable < StandardError; end

  attr_reader :judge, :rubric_version, :calls

  # @param connection [#post] a Faraday connection; the judge's own unless given (tests)
  def initialize judge:, connection: nil
    @judge = judge
    @options = LlmService::DEFAULT_OPTIONS.merge(judge.judge_options)
    @adapter = LlmJudgeAdapters.for(judge.llm_key, @options)
    @connection = connection
    @rubric_version = self.class.rubric_version(judge)
    @calls = 0
  end

  # Changing the prompt or model starts a fresh cache instead of quietly
  # mixing answers given to a different question.
  def self.rubric_version judge
    options = judge.judge_options
    Digest::SHA256.hexdigest([ judge.system_prompt, options[:llm_model], options[:jev_tie_band] ].join("\u0000"))
  end

  def compare pair_x, pair_y
    raise ArgumentError, 'pairs must belong to the same query' unless pair_x.query_text == pair_y.query_text

    flipped = pair_x.id > pair_y.id
    low, high = flipped ? [ pair_y, pair_x ] : [ pair_x, pair_y ]
    winner = (cached(low, high) || ask(low, high)).winner

    winner = { 'a' => 'b', 'b' => 'a' }.fetch(winner, winner) if flipped
    winner.to_sym
  end

  private

  def cached low, high
    PreferenceComparison.for(judge, rubric_version).find_by(query_doc_pair_a_id: low.id, query_doc_pair_b_id: high.id)
  end

  def ask low, high
    swapped = PairwiseSwap.swapped?(low.query_text, low.id, high.id, rubric_version)
    envelope = @adapter.comparison_envelope(low, low.document_fields, high.document_fields,
                                            system_prompt: judge.system_prompt, swapped: swapped)
    answer = @adapter.apply_comparison(post(envelope), swapped: swapped)
    raise Unreadable, "no readable answer comparing pairs #{low.id} and #{high.id}" if answer[:winner].nil?

    store(low, high, swapped, answer)
  end

  def store low, high, swapped, answer
    PreferenceComparison.create!(
      judge: judge, rubric_version: rubric_version, query_text: low.query_text,
      query_doc_pair_a_id: low.id, query_doc_pair_b_id: high.id,
      presented_first: swapped ? 'b' : 'a', winner: answer[:winner],
      probability: answer[:probability], confidence: answer[:confidence],
      input_tokens: answer[:input_tokens], output_tokens: answer[:output_tokens]
    )
  rescue ActiveRecord::RecordNotUnique
    cached(low, high)
  end

  def post envelope
    @calls += 1
    response = connection.post(envelope[:path]) do |req|
      req.headers.merge!(envelope[:headers])
      req.options.timeout = @options[:llm_timeout].to_i
      req.body = envelope[:body]
    end
    raise "LLM API Error: #{response.status} - #{response.body}" unless response.success?

    body = response.body
    body.is_a?(String) ? JSON.parse(body) : body
  end

  def connection
    @connection ||= LlmConnection.build(url: @options[:llm_service_url])
  end
end
