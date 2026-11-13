# Search engine adapters: migration plan

Proposed 2026-11-13. Implements [ADR 0006](../adr/0006-search-engine-adapters.md). **No batch is
implemented yet.** The target is upstream o19s/quepid, so the ADR goes to the o19s maintainers first
(a PR containing only the ADR and this plan). Batch 1 doesn't depend on the ADR and can be the first
code PR. Batch 2 needs the ADR accepted upstream.

Goal: every engine (Solr, Elasticsearch, OpenSearch, Vectara, Algolia, static, Vespa, Qdrant, custom
Search API) is one adapter. The browser and the server both run that adapter, so they can't send
different requests or read responses differently.

## Ground rules for every batch

- **Additive until Batch 7.** The new path sits next to the old one, and each engine switches over on
  its own. The old code is deleted only in Batch 7. This repo fast-forwards from o19s/quepid, so each
  batch should be one upstream PR that merges cleanly.
- **The contract tests are the gate.** `test/fixtures/files/search_engine_contracts/<engine>.json` is
  read by `test/javascript/search_engine_contracts.test.js` (browser) and
  `test/services/search_engine_contracts_test.rb` (server).
  - `expected.browser` may not change. If it has to, that is a behaviour change: list it in the PR and
    get it approved.
  - `expected.server` may change only toward `expected.browser`. Every changed line is listed in the
    PR, and the matching `known_differences` entry is removed.
  - Re-record with `DUMP_CONTRACTS=1` (writes `tmp/contracts/<engine>.{browser,server}.json`), then
    copy the result into the fixture by hand after reviewing the diff.
- **Every batch is complete only when** both contract suites pass, `docker compose exec app rails test`
  and `docker compose exec app yarn test:unit` pass, the linters are clean, and `bin/manual_test_status`
  shows no scenario left stale by the batch's paths.

## Known drift (fixed by this plan, not before)

Each of these is a real bug today. Fixing one ahead of its batch is a one-line change in `FetchService`.
Whether to do that is a separate decision; if it's done, re-record the fixture.

| Drift | Fixed in |
| --- | --- |
| ES: server sends no `size`/`from`, so the case's row count is ignored | Batch 3 |
| ES: server stores no explain | Batch 3 |
| Solr, ES: browser escapes the query text, server doesn't | Batches 3 and 4 |
| Solr: server reads the doc id from a hard-coded `id` field | Batch 4 |
| Vespa: server sends no `hits`, so the case's row count is ignored | Batch 2 |

## Batch 1 — Contracts for every engine and path

No production code changes. Follows the pattern of the existing `solr.json` and `es.json`.

1. New fixtures: `os.json`, `solr_json_dsl.json` (Solr JSON Query DSL, POST), `vectara.json`,
   `algolia.json`, `static.json`, `vespa.json`, `qdrant.json`.
   - Vespa and Qdrant use their preset definitions from `MapperBasedSearchEngine` (query params, mapper
     file) instead of hand-written settings.
   - Vectara, Algolia and static have no server path, so they record `expected.server` as the error
     `RunCaseEvaluationJob` raises today.
2. Extra cases in existing fixtures, or extra fixtures:
   - Solr with `id:movie_id`, which exercises the hard-coded-id drift.
   - A non-200 response (500 with a body) for Solr and ES: what each side reports.
   - `proxy_requests: true`: the browser request goes to `/proxy/fetch?url=…`, so record that URL and
     its params.
   - Solr `explainOther` (`query_runtime.js:362`): the browser request it makes.
3. Server side of the test calls `RunCaseEvaluationJob#extract_docs_based_on_engine` instead of the
   `FetchService` methods directly, so the job's dispatch is covered too.
4. Rename `known_differences` entries "from reading the code" to recorded ones as the new cases pin
   them.

**Done when:** every engine in `SearchEngine::LABELS`, plus Vespa and Qdrant, has a fixture that both
suites run, and every row in the drift table points at a fixture that shows it.

## Batch 2 — Adapter interface and both runtimes, proven on Vespa and Qdrant

Vespa and Qdrant already have the adapter's shape, so they go first.

1. `app/javascript/search_adapters/` (new; plain ES modules with no imports from `app/javascript/utils`,
   because V8 runs them too).
   - `searchapi.js`: wraps a mapper's `docsMapper`/`numberOfResultsMapper`/`ratedDocsQueryParamsMapper`/
     `nextPageArgsMapper`/`requestArgsMapper` as `buildRequest`/`parseResponse`/`nextPage`/`filterToIds`.
     It covers custom endpoints, Vespa and Qdrant.
   - `registry.js`: picks the adapter from `search_engine`.
2. Browser runtime: `app/javascript/utils/adapter_searcher.js`. It takes a request description from
   the adapter and sends it through the existing `createFetchClient` / proxy URL. It exposes
   `search()`, `pager()`, `docs`, `numFound` and `type`, the same as a splainer-search searcher, so
   `query_runtime.js` doesn't change. `createSearcherFromSettings` uses it for `searchapi` only.
3. Server runtime:
   - `V8MapperExecutor` loads the adapter bundle (an esbuild target, like the existing JS builds) and
     gets `build_request`/`parse_response`.
   - `FetchService#make_request` takes a request description and sends it with the existing Faraday
     client.
   - `RunCaseEvaluationJob` uses `parse_response` for `searchapi`.
4. Vespa's `hits` now comes from `buildRequest` on both sides, which closes that drift.

**Done when:** `vespa.json`, `qdrant.json` and any custom-mapper fixture have `expected.server` equal to
`expected.browser` for request and docs. The Vespa and Qdrant Playwright specs (`vespa_wizard`,
`qdrant_wizard`, `qdrant_limits`) pass.

## Batch 3 — Elasticsearch and OpenSearch

1. `search_adapters/es.js`: `buildRequest` (`size`, `from`, `explain`, `_source` from the field spec,
   highlight, escaping, `profile`), `parseResponse` (`hits.total` in both formats, `_id`, `_source`,
   `_explanation`), `nextPage` (`from`), `filterToIds` (`bool.filter` + `terms`). OpenSearch reuses it
   with its own id.
2. The browser switches `es`/`os` to `adapter_searcher.js`. ES explain still goes through
   `esExplainExtractorSvc`, fed with the adapter's raw explain.
3. The server switches `es`/`os` to the adapter, and `extract_docs_from_response_body_for_es`/`_for_os`
   are no longer called.

**Done when:** in `es.json` and `os.json`, `expected.server` equals `expected.browser` for the request
and for id/fields/explain. The `size`, explain and escaping drift rows are removed.

## Batch 4 — Solr

The largest batch: classic GET, JSON DSL POST, JSONP, `explainOther`, and `echoParams`.

1. `search_adapters/solr.js`: `buildRequest` (classic and JSON DSL, `fl`, `wt`, `debug`, `rows`,
   `echoParams`, `hl`, escaping), `parseResponse` (`response.numFound`, docs keyed by the field spec's
   id, `debug.explain`), `nextPage` (`start`), `filterToIds` (`fq` / `filter` with `{!terms f=…}`), and
   `explainOther`.
2. JSONP stays a transport: `adapter_searcher.js` uses JSONP when `api_method` is `JSONP`. The server
   already treats JSONP as GET.
3. `query_runtime.js`'s `explainOther` calls go through the adapter.
4. The server switches `solr` to the adapter. Its doc id now comes from the field spec.

**Done when:** `solr.json`, `solr_json_dsl.json` and the `id:movie_id` fixture have matching server and
browser output. `proxy_controller_test.rb` passes unchanged.

## Batch 5 — Vectara, Algolia, static

1. `search_adapters/vectara.js`, `algolia.js`, `static.js`, ported from splainer-search's searchers for
   these engines.
2. Both runtimes switch to them. Background runs now work for these three engines; until now
   `RunCaseEvaluationJob` raised for them.

**Done when:** their fixtures have matching server and browser output, and the job runs a case on each
engine (one test per engine in `run_case_evaluation_job_test.rb`).

## Batch 6 — Validator and wizard

`searchSvc.createValidator` (used by `wizard_controller.js:393` and `tune_relevance_controller.js:435`)
still builds splainer-search searchers. Move it to the adapter registry: run `buildRequest` with the
endpoint's `test_query` and check that `parseResponse` returns docs and that the field spec's fields
exist.

**Done when:** the wizard Playwright specs (`wizard_behaviour`, `wizard_completion`, `vespa_wizard`,
`qdrant_wizard`) pass and `searchSvc.createSearcher` / `createValidator` have no callers.

## Batch 7 — Delete the old paths

1. Remove `FetchService#add_engine_specific_params`, `add_solr_params`, `add_elasticsearch_params`,
   `add_opensearch_params`, `extract_docs_from_response_body_for_*`, and the engine `case` in
   `RunCaseEvaluationJob#extract_docs_based_on_engine`.
2. Remove the engine branches in `query_service.js` (`buildSearcherRequest`'s Solr/ES argument rules,
   `normalizeSearchResults`' per-engine extractors) and in `rated_docs.js#buildRatedDocsFilter`.
3. `MapperBasedSearchEngine` flags that the adapter now answers (`supports_pagination`,
   `pagination_hits_param`/`pagination_offset_param`, `supports_request_args_mapper`) are removed, or
   kept only where the UI reads them.
4. Collapse each fixture's `expected.browser` and `expected.server` into one `expected`. Both suites
   assert against it.
5. Update `docs/app_structure.md` and `docs/endpoints_*.md`. Mark ADR 0006 Accepted.

**Done when:** `grep -rn "searchSvc\.\|createSearcher" app/javascript` finds nothing, no
`known_differences` remain, and the full Rails, Vitest and Playwright suites pass.

## Out of scope

- Replacing splainer-search's explain rendering (`explainSvc`, `normalDocsSvc`), field specs or
  `docResolverSvc`. A later ADR can decide whether those move too.
- New engines. They become cheap after Batch 2, but each one is its own PR.
- Changing how proxying, credentials or Connections (ADR 0005) work. Adapters produce headers; the
  runtimes keep adding credentials the way they do now.
