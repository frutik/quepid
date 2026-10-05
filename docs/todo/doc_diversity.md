# Result diversity from document embeddings plan

Proposed 2026-10-05. **Not started.** It depends on the `embedders` branch (`docs/todo/embedders.md` there), and implementation begins once that branch is merged into `main`.

A case measures **how different its results are from one another**, not only how relevant they are. Each result document is embedded with the case's embedder, and the per-query diversity is the **intra-list diversity (ILD@k)** of the top k results: the mean pairwise cosine distance between their vectors. It is computed **on demand for a snapshot**, and the text embedded per document is the value of its **title field**, the field the try's field spec maps to `title`.

Diversity is a **separate metric next to the score**, not a scorer:

- A case has exactly one scorer (`cases.scorer_id`). A diversity scorer would replace nDCG/P@k instead of sitting beside it, and "relevance vs. diversity across tries" is the comparison that matters.
- The scorer machinery is built around `docs` + `bestDocs` + ratings. Diversity needs no ratings, only vectors.

Delivered in four phases, each shippable on its own:

1. Document mode for embedders.
2. Document embeddings storage, the text sent per document, and the per-case depth.
3. Diversity computation for a snapshot: service, job, results, API.
4. Case page UI.

## Existing patterns to reuse (after `embedders` is merged)

| Need | Copy from |
| --- | --- |
| Text → vector, batching, truncation, dimension checks | `EmbedderAdapters::Base#embed` |
| Detecting stale vectors | `Embedder#fingerprint` + `text_digest` in `query_vec_meta`; `QueryVectorStatus` |
| Per-case background job with one run at a time | `VectorizeCaseQueriesJob` (SolidQueue `limits_concurrency`) |
| Progress on the core case page | the polled `GET api/cases/:case_id/embedders` (`vectors.running`); core loads no ActionCable |
| Stimulus modal on the core case page | `case_embedder_core_controller.js`, `_case_embedder_core_modal.html.erb` |

## Phase 1: Document mode for embedders

The `embedders` adapters embed **queries** only:

- `Voyage` sends `input_type: "query"`, and `Cohere` sends `input_type: "search_query"`.
- `Embedder#render_input` wraps text in the instruction template (`Instruct: … Query: …`).

Asymmetric models produce a different (worse, for this purpose) vector when a document is embedded as a query. So:

- `Embedder#embed(texts, timeout:, input_type: :query)` gains `input_type` (`:query | :document`) and passes it to the adapter.
- Adapters map it to the provider's value: Voyage `query`/`document`, Cohere `search_query`/`search_document`. OpenAI, Ollama and OpenAI-compatible servers have no such parameter and ignore it.
- For `:document` the instruction/input template is **not applied**. Instruction-following models (Qwen3-Embedding, E5, GTE) embed documents without an instruction.
- `Embedder#document_fingerprint` digests only the settings that change a **document** vector: `provider service_url model dimensions truncation`. Editing the query instruction or template must not invalidate document vectors. Add a comment next to `VECTOR_SETTINGS` saying which settings each fingerprint covers.

Tests: adapter request bodies per provider in both modes; a document embed ignores the instruction; `document_fingerprint` is unchanged by instruction/template edits and changed by model/dimensions edits.

## Phase 2: Storage, text and depth

### `document_embeddings`

Vectors are keyed on the **case**, never on the search endpoint and never globally:

- `doc_id` has no meaning outside a case. The same id in two cases can be two unrelated documents, so there is no global key.
- A case can switch search endpoints between tries, and its documents' vectors stay valid.

```ruby
create_table :document_embeddings do |t|
  t.integer :case_id, null: false
  t.string  :doc_id, limit: 500, null: false
  t.string  :fingerprint, null: false, limit: 64   # Embedder#document_fingerprint
  t.string  :text_digest, null: false, limit: 64   # digest of the exact text sent
  t.integer :dimensions, null: false
  t.binary  :vector, null: false                   # packed little-endian float32
  t.timestamps
end
add_index :document_embeddings, [ :case_id, :fingerprint ]
add_index :document_embeddings, [ :case_id, :doc_id ], length: { doc_id: 191 }   # same prefix as ratings
```

- **Vectors are binary, not JSON.** `vector.pack('e*')` / `unpack('e*')`: 4 bytes per component (6 KB for 1536 dims) against ~15–20 KB of JSON. Nothing reads them outside Ruby, so the JSON readability argument behind `query_vec` doesn't apply. Verify `t.binary` round-trips on both MySQL and PostgreSQL, as `embedders` did for its JSON helpers.
- **One current row per `(case_id, doc_id, fingerprint)`, upserted.** A unique index isn't possible with the prefix-indexed `doc_id`, so the upsert finds the row and updates or creates it inside the job. Only one job runs per case at a time (phase 3), so there's no race.
- A row is **current** when its `fingerprint` matches the case embedder's `document_fingerprint` and its `text_digest` matches the text that would be sent now. Anything else is re-embedded.
- Old rows from a previous embedder stay until the case is deleted, or are pruned by the job: it deletes the case's rows with a different fingerprint after a successful run.
- `Case has_many :document_embeddings, dependent: :delete_all`, and `Case#really_destroy` deletes them explicitly as well, like snapshots/queries. Case clone does **not** copy them (cheap to recompute). Case export does not include them.

### Text sent per document: the title field

The text embedded for a document is the value of the **title field** of the snapshot's try. There is no separate field picker: which field is the title is already configured, in the try's field spec.

- **Which try:** the snapshot's own (`snapshots.try_id`), because that field spec decided which fields the snapshot recorded. A snapshot without a try falls back to the case's latest try.
- **Resolving the title field** follows splainer-search's `fieldSpecSvc` exactly:
  1. an explicit `title:<field>`, or a JSON field definition with `"type": "title"`;
  2. otherwise the first field without a type prefix;
  3. otherwise the id field.

  Port this to Ruby as `FieldSpec.new(field_spec).title_field`. As `embedders` did for `QueryTemplate`, add a fixture of field spec strings and expected title fields, and run it through both the real splainer-search code (Vitest) and the Ruby port (Minitest), so the two can't drift.
- **The title is the id:** when the title field resolves to the id field, embedding ids is meaningless, so the run stops with the status `no_title_field` and tells the user to set `title:<field>` in the field spec.
- **Reading the value from the snapshot:** browser snapshots store `fields[doc.titleField] = doc.title`, keyed by the field's name. `FetchService` snapshots store the raw document (`_source`, or the doc minus `id`). So a dotted name (`title:product.name`) is looked up as a literal key first, then as a nested path. Match how splainer-search reads nested fields (verify before implementing).
- **The value:** strings as is, arrays joined with `, `, anything else as JSON. HTML is left as is, and the field name is not included. A blank value means the doc is skipped and counted in `docs_without_text`.
- `text_digest` is the digest of that text, so a new try whose title field changed re-embeds exactly the documents whose text changed.

### Per-case depth

Stored in its own column, **not in `cases.options`**: `cases.options` is merged into the try's options and sent to the search engine as `qOption` (`Try#options`, `queriesSvc.js`), so a config key there would leak into every search request.

```ruby
add_column :cases, :diversity_depth, :integer # k; nil = 10
```

Tests: `FieldSpec#title_field` parity fixture (explicit `title:`, JSON definition, first bare field, only `id`, `+`-joined specs); text building with a missing, blank, array and nested title; depth validation (2 to 100); upsert and pruning; case delete removes embeddings.

## Phase 3: Diversity for a snapshot

### Input: the snapshot's own documents

Diversity is computed from a **snapshot**, because a snapshot is the only place the server has a query's ordered results together with their titles. Live results exist only in the browser.

- Per `snapshot_query`: its `snapshot_docs` with `rated_only = false`, ordered by `position`, first `diversity_depth`. Rated-only docs were not in the result list and are excluded.
- **Fields must be in the snapshot.** A browser snapshot stores fields only when "Record document fields" is ticked (`promptSnapshot.js`; forced on for engines without lookup by id). `FetchService` snapshots always store them. When fields are recorded, the title field is always among them.
- A snapshot without fields gets the status `no_fields` and a message telling the user to take a snapshot with "Record document fields" ticked. Re-fetching documents by id from the search endpoint is out of scope.

### Metric

For the n top-k documents of a query that have a vector:

```text
ILD@k = 2 / (n·(n−1)) · Σ_{i<j} (1 − cos(v_i, v_j))
```

- Cosine is computed in full (not dot product), so vectors that aren't unit length are fine.
- **n < 2 → `nil`**, not 0: a query with zero or one result has no diversity, and must not drag the case mean down. Same for a query whose snapshot recorded an error.
- Case value: mean over the queries with a non-nil value, plus the count of queries that had one.
- The range is [0, 2] in theory; with text embeddings it is in practice ~[0, 1]. Values are only comparable **across snapshots computed with the same fingerprint, title field and depth** (the UI warns otherwise).

`DiversityCalculator.ild(vectors)` is a pure function with its own unit tests (identical vectors → 0, orthogonal → 1, opposite → 2, n < 2 → nil).

### Service and job

- `DocumentEmbedder.new(kase).embed(docs)`: builds each doc's text, skips the current rows, deduplicates by `doc_id` (the same doc appears under many queries of one snapshot), calls `embedder.embed(texts, input_type: :document)` in batches and upserts per batch. A failed batch is recorded and leaves those docs without a vector instead of failing the run.
- `ComputeSnapshotDiversityJob(snapshot_id, force: false)`:
  1. embeds the snapshot's top-k docs (all of them again with `force`);
  2. computes each `snapshot_query`'s ILD@k and the snapshot mean;
  3. stores the results (below);
  4. prunes the case's embeddings with another fingerprint.

  It uses a per-**case** concurrency key, shared with nothing else, so two snapshots of one case don't embed the same docs in parallel.
- Guard on cost: the job refuses (status `too_large`) when the snapshot would send more than a configured number of new documents (`QUEPID_DIVERSITY_MAX_DOCS`, default 5000), since every run spends the embedder owner's API key.

### Results

```ruby
add_column :snapshot_queries, :diversity, :float
add_column :snapshots, :diversity, :float
add_column :snapshots, :diversity_meta, :json
```

`snapshots.diversity_meta` records how the value was made, so a person and the UI can tell whether two snapshots are comparable:

```json
{
  "status": "done",
  "embedder_id": 7,
  "embedder_name": "Voyage 1024",
  "fingerprint": "ab12cd34ef56ab78",
  "title_field": "name",
  "depth": 10,
  "queries_scored": 48,
  "queries_skipped": 2,
  "docs_embedded": 312,
  "docs_without_text": 3,
  "errors": [],
  "computed_at": "2026-10-05T10:00:00Z"
}
```

`status` is one of `running`, `done`, `failed`, `no_fields`, `no_title_field`, `no_embedder`, `too_large`. A snapshot's diversity is **stale** when its meta's fingerprint or depth no longer match the case. The title field belongs to the snapshot's try and can't go stale, but two snapshots with different title fields are flagged as not comparable. That's computed on read, as `QueryVectorStatus` does for queries.

### API

- `POST api/cases/:case_id/snapshots/:snapshot_id/diversity` (`force=true` to re-embed everything) enqueues the job.
- `GET api/cases/:case_id/snapshots/:snapshot_id/diversity` returns `diversity`, `diversity_meta`, the stale flag, `running`, and per-query `{query_id, diversity}`.
- `diversity` added to `_snapshot.json.jbuilder` and `_snapshot_query.json.jbuilder`, so the existing compare view can read it without another call.
- `PUT api/cases/:case_id/diversity_settings` updates `diversity_depth`.
- Who may trigger it: the same check as assigning an embedder (`current_user.embedders_involved_with`), because it spends the owner's key.

Tests: calculator unit tests; job tests with a stubbed embedder (dedupe across queries, skips current rows, re-embeds when the title text changes, rated-only and beyond-depth docs ignored, `no_fields`, `no_title_field`, partial batch failure, pruning); controller tests including the permission check.

## Phase 4: Case page UI

Per the `angular-case-migration` rule, new UI on the core case page is **Stimulus**, not Angular.

- **Configure and run:** a "Diversity" section in the case's embedder modal (from `embedders` phase 2): the title field the chosen snapshot will use (read-only, with a hint to change it in the try's field spec), depth, a snapshot dropdown, a "Compute diversity" button, and the status from `diversity_meta`. Progress is polled like the vectorization status.
- **Show:** the snapshot's diversity next to its score where snapshots are compared (`queryDiffResults.html`). Per query, show the value beside the snapshot's per-query score, and add a stale/incomparable badge when the two snapshots' meta differ in fingerprint, title field or depth. Reading the values comes from the snapshot JSON (phase 3); the Angular template only renders them.
- Without an embedder on the case the section says so and links to the embedder picker.

## Docs and manual tests (same PRs)

- `docs/data_mapping.md`: `document_embeddings`, `cases.diversity_depth`, `snapshot_queries.diversity`, `snapshots.diversity`, `snapshots.diversity_meta`.
- `docs/app_structure.md`: `FieldSpec`, `DocumentEmbedder`, `DiversityCalculator`, `ComputeSnapshotDiversityJob`.
- `docs/vector_search.md` (from `embedders`): a section on diversity and the document input type.
- `docs/manual-testing/`: new scenarios (compute for a snapshot with fields, a snapshot without fields shows `no_fields`, a field spec without a title shows `no_title_field`, change the embedder or depth → stale, compare two snapshots, including two tries with different title fields), with `paths` in `tracking.yml`.

## Open questions

1. **Default depth:** fixed 10, or follow the case scorer's k when it has one?
2. **Title only:** short titles (product names) may be too thin to separate documents well. If so, a later option could append the try's `sub` fields, values only, without field labels: labels add tokens shared by every doc, which pulls all vectors together and compresses the diversity range.
3. **Snapshots without fields:** is "take a new snapshot with fields" enough, or should phase 3 re-fetch docs by id from the search endpoint (needs `FetchService` lookup support per engine)?
4. **Live results:** worth computing diversity for the current try in the browser (needs vectors sent to the page, ~6 KB per doc) or is snapshot-only enough?
5. **Other diversity measures:** coverage-style metrics (α-nDCG, subtopic recall) need labelled aspects, so they're out of scope. Is a clustering-based "number of distinct groups in the top k" wanted alongside ILD?
