# ADR 0006 — Search engine adapters: one definition per engine, run by the browser and the server

- **Status:** Proposed (to be agreed with the o19s maintainers before the plan's Batch 2)
- **Date:** 2026-11-13
- **Affects (when built):** `app/javascript/utils/query_service.js`, `app/javascript/utils/query_runtime.js`,
  `app/javascript/utils/rated_docs.js`, `app/javascript/utils/live_query_runtime_owner.js`,
  `app/services/fetch_service.rb`, `app/jobs/run_case_evaluation_job.rb`, `lib/v8_mapper_executor.rb`,
  `lib/mapper_code_logic.js`, `app/models/mapper_based_search_engine.rb`, `db/mapper_based_search_engines/*.js`
- **Plan:** [docs/todo/search_engine_adapters.md](../todo/search_engine_adapters.md)

---

## 1. Context

Quepid talks to search engines in two different ways.

**Built-in engines** (`solr`, `es`, `os`, `vectara`, `algolia`, `static`; `app/models/search_engine.rb`).
The browser uses splainer-search, which has its own searcher, preprocessor, doc factory and explain
extractor for each engine. Background runs (`FetchService`, `RunCaseEvaluationJob`) use separate Ruby
code: per-engine parameters in `add_engine_specific_params`, and per-engine `extract_docs_from_response_body_for_*`.
Only Solr, ES, OpenSearch and `searchapi` have that Ruby code. Vectara, Algolia and static raise
`Search engine … is not supported` in `run_case_evaluation_job.rb`.

**Mapper-based engines** (Vespa, Qdrant, and any custom `searchapi` endpoint). These are all the
generic `searchapi` engine plus JavaScript in `db/mapper_based_search_engines/*.js`
(`docsMapper`, `numberOfResultsMapper`, `ratedDocsQueryParamsMapper`, `nextPageArgsMapper`,
`requestArgsMapper`, …). `MapperBasedSearchEngine::DEFINITIONS` holds the flags for each preset. The same
JavaScript runs in the browser (`new Function`) and on the server (`V8MapperExecutor`).

So every built-in engine is written twice, once in splainer-search and once in Ruby, and the two copies
have drifted apart. The characterization tests in `test/fixtures/files/search_engine_contracts/` record
what each side does today:

| Drift | Engine | Fixture |
| --- | --- | --- |
| Server sends no `size`/`from`, so the case's row count is ignored | ES | `es.json` |
| Server stores no explain for ES docs | ES | `es.json` |
| Browser escapes the query text (`escape_query` defaults to true), server doesn't | Solr, ES | `solr.json`, `es.json` |
| Server reads the Solr doc id from a hard-coded `id` field, not the field spec | Solr | `solr.json` (from reading the code; not yet exercised) |
| Server sends no `hits`, so the case's row count is ignored | Vespa | none yet |

The mapper engines don't have this problem for the parts they share, because both sides run one
definition. They have the opposite problem: anything the mapper doesn't cover (`hits` for Vespa) falls
through to generic code on each side, and the two sides fill the gap differently.

## 2. Decision

Every engine, built-in or mapper-based, becomes an **adapter**: a set of plain JavaScript functions
that both runtimes execute. The browser calls them directly. The server runs them in
`V8MapperExecutor`, which it already does for mappers.

An adapter is pure. It never does I/O:

| Function | In | Out |
| --- | --- | --- |
| `buildRequest` | settings (url, args, field spec, rows, escape, api method, options), query text, query options | `{ method, url, params, body, headers }` |
| `parseResponse` | response body, field spec | `{ numFound, docs: [{ id, fields, explain }] }`, with `explain` as the engine's raw explain JSON |
| `nextPage` | the request it built, rows already fetched, numFound | the next request, or `null` |
| `filterToIds` | the request, ids, id field | the request restricted to those ids, or `null` when the engine can't do that |
| `explainOther` (optional; Solr only today) | the request, a filter | the request that asks for explain on other docs |

Things that are **not** part of an adapter, and stay with each runtime:

- **Transport:** fetch, JSONP, the Quepid proxy (`ProxyController`), Faraday. A runtime takes the
  request description and sends it the way it already does.
- **Explain rendering:** `explainSvc`, hot matches and the normalized-doc model stay shared and come
  after the adapter. The adapter only hands over raw explain.
- **Query templating:** `#$query##`, curator variables and `qOption` hydration already have one tested
  definition (`queryTemplateSvc` and `QueryTemplate`, held together by `query_template_parity.test.js`).

Persisted data doesn't change. `search_endpoints.search_engine` keeps its values (`solr`, `es`, …) and
picks the built-in adapter. Presets keep `mapper_based_search_engine_id`. A custom `searchapi` endpoint's
`mapper_code` keeps working, because a small wrapper turns `docsMapper`/`numberOfResultsMapper`/… into
the adapter functions above.

## 3. Options considered

1. **One adapter per engine, run in the browser and in V8 on the server (chosen).** This gives one
   definition per engine and ends the drift by construction. It reuses `V8MapperExecutor` and the
   mapper pattern that Vespa and Qdrant already prove. Vectara, Algolia and static get background runs
   for free. Cost: Quepid-owned JavaScript replaces most of what splainer-search does for searching.
2. **Run splainer-search itself in V8 on the server.** This also ends the drift, but keeps two
   architectures (splainer-search engines plus mapper engines), which is the thing this ADR exists to
   remove. splainer-search also expects `fetch`, JSONP and DOM-free globals, which a V8 context has to
   fake.
3. **Send every search through the server** (`FetchService` behind the proxy), and drop browser-side
   searching. Rejected: endpoints that only the user's browser can reach (localhost, a VPN, an intranet)
   would stop working, and that is one of Quepid's main uses.
4. **Keep both, and fix the drift case by case.** This is cheapest today. But the five rows in §1 show
   that two copies drift, and every new engine or option adds a third place to update.

## 4. Consequences

- The characterization fixtures become the specification of each engine. A migration batch may change
  the server's recorded output only toward the browser's, and must list every line it changes. The
  browser's recorded output may not change.
- splainer-search is still used for explain rendering (`explainSvc`, `normalDocsSvc`), field specs and
  the snapshot doc resolver until a later decision. This ADR doesn't remove the dependency.
- The adapter code is JavaScript that the server runs in V8. Mapper code already works this way, so
  this adds no new runtime. The adapters are first-party files, though, not user input.
- The work lands in o19s/quepid in small PRs that add the new path next to the old one, and remove the
  old path only at the end.
- The adapters could instead live in splainer-search, which is also an o19s package, so that other
  tools such as Splainer get them too. This ADR keeps them in Quepid
  (`app/javascript/search_adapters/`) so that no change waits on a package release. Moving them into
  splainer-search later is possible, because the adapters are pure functions with no Quepid imports.
