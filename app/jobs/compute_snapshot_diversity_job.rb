# frozen_string_literal: true

# Measures how different the top results of each query in a snapshot are from one another
# (intra-list diversity, see DiversityCalculator), using the case's embedder to vectorise
# each result's title.
#
# It reads the snapshot because that is the only place the server has a query's ordered
# results together with their fields. The outcome is stored on the snapshot -- a value per
# query and a mean -- with `diversity_meta` recording how it was made (status, embedder,
# fingerprint, title field, depth, counts), so a person and the UI can tell whether two
# snapshots are comparable and whether one is stale. Progress isn't pushed: the case page
# polls Api::V1::Snapshots::DiversityController, which also asks running?.
class ComputeSnapshotDiversityJob < ApplicationJob
  queue_as :bulk_processing

  # Embedding spends the embedder owner's API key.
  MAX_DOCS_ENV = 'QUEPID_DIVERSITY_MAX_DOCS'
  DEFAULT_MAX_DOCS = 5000

  # One run per case at a time, so two snapshots of a case don't embed the same documents in
  # parallel; the second then finds them already stored.
  limits_concurrency to:       1,
                     key:      ->(snapshot, **) { "snapshot_diversity_case_#{snapshot.case_id}" },
                     duration: 30.minutes

  def self.enqueue_for snapshot, force: false
    perform_later(snapshot, force: force)
  end

  def self.max_docs
    ENV.fetch(MAX_DOCS_ENV, DEFAULT_MAX_DOCS).to_i
  end

  # Is a run for this snapshot queued or in progress? Mirrors VectorizeCaseQueriesJob.running?.
  def self.running? snapshot
    return false unless solid_queue?

    gid = snapshot.to_global_id.to_s
    SolidQueue::Job
      .where(class_name: name, finished_at: nil)
      .where.missing(:failed_execution)
      .where('arguments LIKE ?', "%#{gid}%")
      .any? { |job| (job.arguments['arguments'] || []).any? { |a| a.is_a?(Hash) && a['_aj_globalid'] == gid } }
  end

  def self.solid_queue?
    :solid_queue == Rails.application.config.active_job.queue_adapter && defined?(SolidQueue::Job)
  end
  private_class_method :solid_queue?

  def perform snapshot, force: false
    @snapshot = snapshot
    @case = snapshot.case
    @embedder = @case&.effective_diversity_embedder
    @depth = @case&.effective_diversity_depth

    return if @case.nil?
    return finish(:no_embedder) if @embedder.nil?

    field_spec = FieldSpec.new((snapshot.try || @case.tries.first)&.field_spec)
    @title_field = field_spec.title_field
    return finish(:no_title_field) if field_spec.title_is_id?

    snapshot.update!(diversity_meta: meta(:running))
    compute(force)
  rescue StandardError => e
    finish(:failed, errors: [ e.message ])
    raise
  end

  private

  def compute force
    top_docs = top_docs_by_snapshot_query
    docs = top_docs.values.flatten
    return finish(:no_fields) if docs.none? { |doc| doc.fields.present? }

    texts = texts_for(docs)
    embedder = DocumentEmbedder.new(@case, @embedder)
    pending = embedder.pending(texts, force: force)
    return finish(:too_large, errors: [ "#{pending.size} documents to embed, over the limit of #{self.class.max_docs}" ]) if pending.size > self.class.max_docs

    result = embedder.embed(pending)
    vectors = DocumentEmbedding.vectors_for(case_id: @case.id, fingerprint: embedder.fingerprint, doc_ids: texts.keys)

    scored = score(top_docs, vectors)
    prune(embedder.fingerprint)
    finish(:done, errors: result.errors.uniq, scored: scored, docs_embedded: result.embedded,
                  docs_without_text: docs.map(&:doc_id).uniq.size - texts.size)
  end

  # { SnapshotQuery => [SnapshotDoc] }: each query's first `depth` results in order. Rated-only
  # docs weren't in the result list, so they don't count.
  def top_docs_by_snapshot_query
    snapshot_queries = @snapshot.snapshot_queries.to_a
    docs = SnapshotDoc.where(snapshot_query_id: snapshot_queries.map(&:id), rated_only: false)
      .select(:id, :snapshot_query_id, :doc_id, :position, :fields)
      .order(:position, :id)
      .group_by(&:snapshot_query_id)

    snapshot_queries.index_with { |snapshot_query| (docs[snapshot_query.id] || []).first(@depth) }
  end

  # { doc_id => text } for the docs that have some; a doc under several queries counts once.
  def texts_for docs
    docs.each_with_object({}) do |doc, texts|
      next if texts.key?(doc.doc_id)

      text = DocumentText.for(parse_fields(doc.fields), @title_field)
      texts[doc.doc_id] = text if text
    end
  end

  def parse_fields json
    json.present? ? JSON.parse(json) : nil
  rescue JSON::ParserError
    nil
  end

  # Stores each query's ILD and returns the values of those that have one.
  def score top_docs, vectors
    values = []
    top_docs.each do |snapshot_query, docs|
      value = snapshot_query.error.present? ? nil : DiversityCalculator.ild(docs.filter_map { |doc| vectors[doc.doc_id] })
      snapshot_query.update_columns(diversity: value)
      values << value if value
    end
    { values: values, queries: top_docs.size }
  end

  def prune fingerprint
    DocumentEmbedding.where(case_id: @case.id).where.not(fingerprint: fingerprint).delete_all
  end

  def finish status, errors: [], scored: nil, docs_embedded: 0, docs_without_text: 0
    values = scored ? scored[:values] : []
    @snapshot.snapshot_queries.update_all(diversity: nil) unless scored
    counts = { 'queries_scored'    => values.size,
               'queries_skipped'   => scored ? scored[:queries] - values.size : 0,
               'docs_embedded'     => docs_embedded,
               'docs_without_text' => docs_without_text }
    @snapshot.update!(
      diversity:      values.empty? ? nil : values.sum / values.size,
      diversity_meta: meta(status, errors: errors, counts: counts)
    )
  end

  def meta status, errors: [], counts: {}
    {
      'status'            => status.to_s,
      'embedder_id'       => @embedder&.id,
      'embedder_name'     => @embedder&.name,
      'fingerprint'       => @embedder&.document_fingerprint,
      'title_field'       => @title_field,
      'depth'             => @depth,
      'queries_scored'    => 0,
      'queries_skipped'   => 0,
      'docs_embedded'     => 0,
      'docs_without_text' => 0,
      'errors'            => errors,
      'computed_at'       => Time.current.utc.iso8601,
    }.merge(counts)
  end
end
