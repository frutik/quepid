# frozen_string_literal: true

require 'test_helper'

# The server side of test/fixtures/files/search_engine_contracts/*.json; the browser side
# (splainer-search) runs the same fixtures in test/javascript/search_engine_contracts.test.js.
# Characterization tests: they pin what FetchService sends for each engine and which docs it
# reads back today, so moving the engines to one architecture can be checked against them.
# A failure means the behaviour changed.
class SearchEngineContractsTest < ActiveSupport::TestCase
  FIXTURE_DIR = Rails.root.join('test/fixtures/files/search_engine_contracts')

  # The same shape the JS side builds: params grouped by key, JSON body parsed.
  def canonical_request request
    params = URI.decode_www_form(request.uri.query.to_s).each_with_object({}) do |(key, value), grouped|
      (grouped[key] ||= []) << value
    end
    {
      'method' => request.method.to_s.upcase,
      'url'    => request.uri.omit(:query).normalize.to_s,
      'params' => params,
      'body'   => request.body.present? ? JSON.parse(request.body) : nil,
    }
  end

  # Symbol keys and the JSON-encoded explain become plain JSON, as they are stored.
  def json_docs docs
    docs.map do |doc|
      json = doc.as_json
      json['explain'] = JSON.parse(json['explain']) if json['explain']
      json
    end
  end

  %w[solr es].each do |engine|
    describe engine do
      let(:fixture) { JSON.parse(File.read(FIXTURE_DIR.join("#{engine}.json"))) }
      let(:endpoint) do
        SearchEndpoint.new(search_engine: fixture['search_engine'], endpoint_url: fixture['search_url'],
                           api_method: fixture['api_method'])
      end
      let(:atry) do
        Try.new(query_params: fixture['query_params'], field_spec: fixture['field_spec'],
                number_of_rows: fixture['number_of_rows'], search_endpoint: endpoint)
      end
      let(:query) { Query.new(query_text: fixture['query_text']) }

      it 'parses query_params into the args the browser receives' do
        assert_equal fixture['expected']['args'], atry.args.as_json
      end

      it 'sends the recorded request and reads the recorded response' do
        requests = []
        stub_request(:any, /#{Regexp.escape(URI(fixture['search_url']).host)}/).to_return do |request|
          requests << canonical_request(request)
          { status: 200, body: fixture['response'].to_json }
        end

        fetch_service = FetchService.new(debug_mode: false)
        response = fetch_service.make_request(atry, query)
        docs = fetch_service.public_send("extract_docs_from_response_body_for_#{engine}", response.body)

        actual = { 'requests' => requests, 'docs' => json_docs(docs) }
        # DUMP_CONTRACTS=1 writes the actual output, to re-record a fixture after an intended change.
        if ENV['DUMP_CONTRACTS']
          FileUtils.mkdir_p(Rails.root.join('tmp/contracts'))
          File.write(Rails.root.join("tmp/contracts/#{engine}.server.json"), JSON.pretty_generate(actual))
        end

        assert_equal 200, response.status
        assert_equal fixture['expected']['server'], actual
      end
    end
  end
end
