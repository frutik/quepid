# frozen_string_literal: true

require 'test_helper'

class ComputeSnapshotDiversityJobTest < ActiveJob::TestCase
  URL = 'https://api.openai.com/v1/embeddings'

  let(:embedder) { embedders(:openai_small) }
  let(:acase)    { cases(:shared_with_team) }
  let(:the_try) { acase.tries.create!(field_spec: 'id:id title:name') }
  let(:snapshot) { acase.snapshots.create!(name: 'diverse', try: the_try) }

  # A vector per text, taken from a table so tests choose how similar two titles are.
  VECTORS = {
    'Star Wars'     => [ 1.0, 0.0, 0.0 ],
    'The Empire'    => [ 1.0, 0.0, 0.0 ],
    'Casablanca'    => [ 0.0, 1.0, 0.0 ],
    'Alien'         => [ 0.0, 0.0, 1.0 ],
    'A Quiet Place' => [ 0.0, 1.0, 1.0 ],
  }.freeze

  def respond_with_table
    stub_request(:post, URL).to_return do |request|
      inputs = JSON.parse(request.body)['input']
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: inputs.each_with_index.map { |text, i| { index: i, embedding: VECTORS.fetch(text) + Array.new(509, 0.0) } } }.to_json }
    end
  end

  # titles: array of titles in result order (nil entries have no title field)
  def add_query text, titles, error: nil, rated_only_ids: []
    query = acase.queries.create!(query_text: text)
    snapshot_query = snapshot.snapshot_queries.create!(query: query, error: error)
    titles.each_with_index do |title, index|
      # The same title is the same document, whichever query shows it.
      snapshot_query.snapshot_docs.create!(doc_id: title ? "doc-#{title}" : "#{text}-#{index}", position: index + 1,
                                           fields: title ? { 'name' => title }.to_json : { 'other' => 'x' }.to_json)
    end
    rated_only_ids.each do |doc_id|
      snapshot_query.snapshot_docs.create!(doc_id: doc_id, position: 99, rated_only: true, fields: { 'name' => 'Alien' }.to_json)
    end
    snapshot_query
  end

  setup do
    acase.queries.destroy_all
    acase.update!(embedder: embedder, diversity_depth: nil)
  end

  test 'scores each query and the snapshot mean' do
    same = add_query('same', [ 'Star Wars', 'The Empire' ])
    apart = add_query('apart', [ 'Star Wars', 'Casablanca', 'Alien' ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_in_delta 0.0, same.reload.diversity, 1.0e-6
    assert_in_delta 1.0, apart.reload.diversity, 1.0e-6
    snapshot.reload

    assert_in_delta 0.5, snapshot.diversity, 1.0e-6
    meta = snapshot.diversity_meta

    assert_equal 'done', meta['status']
    assert_equal 'name', meta['title_field']
    assert_equal 10, meta['depth']
    assert_equal embedder.document_fingerprint, meta['fingerprint']
    assert_equal 2, meta['queries_scored']
    assert_equal 0, meta['queries_skipped']
    assert_equal 4, meta['docs_embedded'] # Star Wars once, even though two queries show it
    assert_not_predicate snapshot, :diversity_stale?
  end

  test 'embeds each title once, as a document' do
    add_query('one', [ 'Star Wars', 'Casablanca' ])
    add_query('two', [ 'Star Wars', 'Alien' ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_requested(:post, URL, times: 1) { |request| [ 'Star Wars', 'Casablanca', 'Alien' ].sort == JSON.parse(request.body)['input'].sort }
  end

  test 'only looks at the first depth results and ignores rated-only docs' do
    acase.update!(diversity_depth: 2)
    query = add_query('deep', [ 'Star Wars', 'The Empire', 'Casablanca', 'Alien' ], rated_only_ids: [ 'rated' ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_in_delta 0.0, query.reload.diversity, 1.0e-6 # only Star Wars and The Empire
    assert_equal 2, snapshot.reload.diversity_meta['depth']
    assert_requested(:post, URL) { |request| [ 'Star Wars', 'The Empire' ] == JSON.parse(request.body)['input'] }
  end

  test 'a query with fewer than two results or an error has no diversity and is not averaged in' do
    lonely = add_query('lonely', [ 'Star Wars' ])
    broken = add_query('broken', [ 'Star Wars', 'Casablanca' ], error: 'boom')
    apart = add_query('apart', [ 'Star Wars', 'Casablanca' ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_nil lonely.reload.diversity
    assert_nil broken.reload.diversity
    assert_in_delta 1.0, apart.reload.diversity, 1.0e-6
    assert_in_delta 1.0, snapshot.reload.diversity, 1.0e-6
    assert_equal 1, snapshot.diversity_meta['queries_scored']
    assert_equal 2, snapshot.diversity_meta['queries_skipped']
  end

  test 'a second run embeds nothing new, force embeds everything again' do
    add_query('apart', [ 'Star Wars', 'Casablanca' ])
    stub = respond_with_table
    ComputeSnapshotDiversityJob.perform_now(snapshot)
    WebMock::RequestRegistry.instance.reset!

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_not_requested stub
    assert_equal 0, snapshot.reload.diversity_meta['docs_embedded']
    assert_in_delta 1.0, snapshot.diversity, 1.0e-6

    ComputeSnapshotDiversityJob.perform_now(snapshot, force: true)

    assert_requested stub, times: 1
  end

  test 're-embeds exactly the documents whose title changed' do
    query = add_query('apart', [ 'Star Wars', 'Casablanca' ])
    respond_with_table
    ComputeSnapshotDiversityJob.perform_now(snapshot)
    WebMock::RequestRegistry.instance.reset!
    query.snapshot_docs.find_by(position: 2).update!(fields: { 'name' => 'Alien' }.to_json)

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_requested(:post, URL, times: 1) { |request| [ 'Alien' ] == JSON.parse(request.body)['input'] }
  end

  test 'a title that is the id stops the run with no_title_field' do
    the_try.update!(field_spec: 'id:id title:id *')
    add_query('apart', [ 'Star Wars', 'Casablanca' ])

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_equal 'no_title_field', snapshot.reload.diversity_meta['status']
    assert_nil snapshot.diversity
    assert_not_requested :post, URL
  end

  test 'a snapshot that recorded no fields stops with no_fields' do
    query = acase.queries.create!(query_text: 'bare')
    snapshot.snapshot_queries.create!(query: query).snapshot_docs.create!(doc_id: 'a', position: 1)

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_equal 'no_fields', snapshot.reload.diversity_meta['status']
    assert_not_requested :post, URL
  end

  test 'a case without an embedder stops with no_embedder' do
    acase.update!(embedder: nil)
    add_query('apart', [ 'Star Wars', 'Casablanca' ])

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_equal 'no_embedder', snapshot.reload.diversity_meta['status']
  end

  test 'refuses to embed more than the configured number of new documents' do
    add_query('apart', [ 'Star Wars', 'Casablanca', 'Alien' ])

    ENV[ComputeSnapshotDiversityJob::MAX_DOCS_ENV] = '2'
    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_equal 'too_large', snapshot.reload.diversity_meta['status']
    assert_not_requested :post, URL
  end

  test 'a failed batch leaves its documents out and is reported' do
    query = add_query('apart', [ 'Star Wars', 'Casablanca', 'Alien' ])
    stub_request(:post, URL).to_return(status: 500, body: 'down')

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    snapshot.reload

    assert_equal 'done', snapshot.diversity_meta['status']
    assert_not_empty snapshot.diversity_meta['errors']
    assert_nil query.reload.diversity
    assert_nil snapshot.diversity
  end

  test 'prunes vectors made with another fingerprint after a run' do
    add_query('apart', [ 'Star Wars', 'Casablanca' ])
    DocumentEmbedding.store(case_id: acase.id, fingerprint: 'old', rows: [ { doc_id: 'x', text_digest: 'd', vector: [ 1.0 ] } ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_equal [ embedder.document_fingerprint ], DocumentEmbedding.where(case_id: acase.id).distinct.pluck(:fingerprint)
  end

  test 'is stale once the embedder or depth changes, and comparable only with the same settings' do
    add_query('apart', [ 'Star Wars', 'Casablanca' ])
    respond_with_table
    ComputeSnapshotDiversityJob.perform_now(snapshot)
    snapshot.reload

    assert_not_predicate snapshot, :diversity_stale?

    acase.update!(diversity_depth: 5)

    assert_predicate snapshot.reload, :diversity_stale?

    acase.update!(diversity_depth: nil)
    embedder.update!(model: 'text-embedding-3-large')

    assert_predicate snapshot.reload, :diversity_stale?

    other = acase.snapshots.create!(name: 'other', diversity_meta: snapshot.diversity_meta.merge('depth' => 3))

    assert_not snapshot.diversity_comparable_with?(other)
    assert snapshot.diversity_comparable_with?(snapshot)
  end

  teardown { ENV.delete(ComputeSnapshotDiversityJob::MAX_DOCS_ENV) }

  test 'uses the case\'s diversity embedder when it has one' do
    other = Embedder.create!(name: 'Other', provider: 'openai', service_url: 'https://api.openai.com',
                             model: 'text-embedding-3-large', api_key: 'sk-other', owner: users(:random))
    acase.update!(diversity_embedder: other)
    add_query('apart', [ 'Star Wars', 'Casablanca' ])
    respond_with_table

    ComputeSnapshotDiversityJob.perform_now(snapshot)

    assert_requested(:post, URL) { |request| 'text-embedding-3-large' == JSON.parse(request.body)['model'] }
    assert_equal other.id, snapshot.reload.diversity_meta['embedder_id']
  end

  test 'enqueues on the bulk_processing queue' do
    assert_enqueued_with(job: ComputeSnapshotDiversityJob, queue: 'bulk_processing') do
      ComputeSnapshotDiversityJob.enqueue_for(snapshot)
    end
  end
end
