# ADR 0002 — Result diversity: ILD as a scorer, embedded on the server, embedder chosen on the case

- **Status:** Accepted
- **Date:** 2026-10-28
- **Affects:** `db/scorers/ild@10.js`, `app/javascript/utils/scorer_runtime.js`,
  `app/services/result_diversity.rb`, `app/services/document_embedder.rb`,
  `app/services/diversity_calculator.rb`, `app/models/document_embedding.rb`,
  `app/controllers/api/v1/case_diversity_scores_controller.rb`,
  `app/controllers/api/v1/case_scorers_controller.rb`, `app/services/fetch_service.rb`,
  `lib/javascript_scorer.rb`, `app/javascript/controllers/pick_scorer_core_controller.js`
- **Builds on:** `docs/todo/embedders.md` (the `Embedder` and its adapters)
- **Plan and history:** `docs/todo/doc_diversity.md`

---

## 1. Context

Quepid measures relevance. We also want to know **how different the top results of a query are
from one another**: intra-list diversity (ILD), the mean pairwise cosine distance between the
embeddings of the results. 0 means all alike, about 1 means unrelated.

Three facts shaped the design:

- **The browser can't embed.** Embedding is an HTTP call that spends an `Embedder` owner's API
  key. Keys never reach the page.
- **Scorers run in two places.** A scorer's JavaScript is the same file
  (`scorer_runtime.js`) in the browser and, through MiniRacer, on the server for nightly runs and
  Run case evaluation. MiniRacer has no network.
- **A scorer is shared; an embedder is a credential.** Communal scorers are visible to everyone.
  An embedder is owned by one person and shared with named teams.

The first implementation measured diversity per **snapshot**, as a metric next to the score.
That was replaced as the main path by the decision below, and kept only for existing snapshots.

## 2. Decision

### 2.1 ILD is a scorer, not a separate metric

ILD@10 is a communal `Scorer` whose code is `scoreByDiversity(10);`. It is picked in the existing
scorer dialog like nDCG@10, and its numbers flow through the existing score, snapshot and
comparison paths with no new columns.

`scoreByDiversity(k)` is a helper of `scorer_runtime.js`. It sends the first `k` results' ids and
titles to a `diversity` function **injected into `createScorer`**, the same way
`refreshRatedDocs` already is, and scores with what comes back. Without that function the scorer
errors rather than guessing. No results at all stays `"zsr"`. Fewer than two results with a title
is no score, not 0, so it is left out of the case average.

### 2.2 The value is worked out on the server, once, in Ruby

Both runtimes end in the same service, `ResultDiversity`
(`DocumentEmbedder` + `DiversityCalculator`):

- **Browser:** the injected function posts the titles to
  `POST api/cases/:case_id/diversity/score`.
- **Server (nightly, Run case evaluation):** `FetchService#score_snapshot` computes the value
  before running the scorer and passes it to `JavascriptScorer`, whose adapter hands it to
  `scoreByDiversity`. MiniRacer never needs the network.

The scorer's depth is the argument of its call (`Scorer#diversity_depth`), so the code is the
single source of truth in both places.

### 2.3 Results are embedded as documents, cached per case

- **Document mode.** `Embedder#embed(texts, input_type: :document)`: Voyage `document`, Cohere
  `search_document`, no instruction or input template. Models that take an instruction take it on
  queries only.
- **Cache.** `document_embeddings`, one row per `(case_id, doc_id, fingerprint)`. It is keyed on
  the **case** because a `doc_id` means nothing outside it, and a case can switch search
  endpoints. A row is current when its `fingerprint` and the `text_digest` of the exact text
  still match.
- **Two fingerprints.** `Embedder#document_fingerprint` covers provider, URL, model, dimensions
  and truncation. Editing a query instruction leaves document vectors valid;
  `Embedder#fingerprint` still covers everything for query vectors.
- **Binary vectors.** Packed little-endian float32 in a `BLOB`/`bytea`, not JSON: 4 bytes per
  component, and nothing reads them outside Ruby. The limit is 16,383 dimensions, the MySQL `BLOB`
  size, applied on every adapter so they behave alike. Writes are one `upsert_all` per batch
  (`unique_by:` on PostgreSQL and SQLite, not on MySQL).
- **The text** is the value of the snapshot try's (or the live try's) **title field**, resolved
  by `FieldSpec`, a Ruby port of splainer-search's id/title rules. A fixture
  (`field_spec_cases.json`) runs through both implementations so they can't drift. If the title
  is the id there is nothing to embed and the scorer gives no score.

### 2.4 The embedder is a setting of the case, chosen where the scorer is chosen

`cases.diversity_embedder_id`, optional; blank means the case's own `embedder_id`
(`Case#effective_diversity_embedder`). The scorer dialog shows an **Embedder for result
diversity** dropdown when the selected scorer `uses_diversity?`, and saves it with the scorer
(`PUT api/cases/:case_id/scorers/:id`, `diversity_embedder_id`).

- It is a separate setting because ILD only compares documents with each other. The query and
  document vectors don't have to come from the same model, so diversity can use a cheaper one.
- The scorer stays free of credentials. Every use re-checks that the user can see the embedder,
  on a case they are involved with, exactly as assigning a query embedder does.
- A clone keeps it only if the cloning user can see it. Deleting the embedder clears it.

### 2.5 A scorer says whether it reads ratings

ILD never looks at ratings; EILD (expected ILD, which weights results by relevance) would.
`Scorer#uses_ratings?` is false only for a scorer that calls `scoreByDiversity` and no rating
helper (`avgRating`, `docRating`, `topRatings`, ...), and is sent to the page as `uses_ratings`.
When false, `scoreQuery` reports every query as fully rated, so the per-query "unrated" badge, the
Frog Report's "ratings needed" counts and the unrated sort say nothing for ILD. Nothing else is
hidden by this rule alone. The scorer
code is the only declaration, so the dialog needs no extra label.

> **Amended the same day:** the rating controls are locked too, not just the nags. While such a
> scorer is the case's scorer, `utils/ratings_lock.js` puts `scorer-no-ratings` on `<body>`, and
> "Score All", the per-result rating buttons and Missing Documents stay on the page but dimmed
> and disabled, with the tooltip "The current scorer doesn't use ratings". They are locked, not
> hidden, so ratings already given stay visible and the layout doesn't move when the scorer
> changes. Controls rendered later (queries are shown lazily) lock themselves when they connect.
> The scorer edit form shows no grade scale for such a scorer, only the note "This scorer
> doesn't use ratings, so it has no grade scale"; saving leaves the stored scale as it was. It
> reads the saved code, so a scorer whose code was just changed updates after the next save.
> A user who wants to rate switches scorer. (This replaces "rating buttons stay" above.)

### 2.6 ILD keeps the default rating scale

A scorer's `scale` is also the case's **rating scale**. ILD@10 is seeded with 0 to 3 and the
default labels, so choosing it does not change how documents are rated.

## 3. Alternatives rejected

- **Diversity as a metric next to the score** (the first implementation). It would have kept
  relevance and diversity in view together. Rejected by product decision: ILD belongs in the
  scorer list. The cost is below.
- **The embedder as an attribute of the scorer.** A communal scorer pointing at a private
  embedder would let everyone using the scorer spend its owner's key, and the scorer would
  change meaning when switched between cases.
- **Embedding in MiniRacer, or sending vectors to the page.** No network there; about 6 KB per
  document to the page for no benefit, since only the score is needed.
- **A `kind` column on `scorers`.** The helper name in the code is enough to know a scorer needs
  an embedder, and it keeps the scorer editable like any other.
- **Similarity of each result to the query.** It needs query and document vectors from the same
  model, which 2.4 deliberately rules out, and it is a second relevance signal next to ratings.

## 4. Consequences

- **One scorer per case.** While ILD@10 is selected the case has no nDCG or AP. You can no longer
  watch relevance and diversity move together on one case.
- **Live searches can spend money.** Every search of a query whose top results aren't cached
  makes an embedding call on the owner's key. The cache means each result costs once per case and
  embedder setting; there is no per-user rate limit beyond the 100-document request cap.
- **Titles leave the system** to the embedding provider, as they already do for snapshots.
- **A provider error is a scorer error:** the query shows no score, with the provider's message.
- **Changing the embedder's model or size re-embeds** the first page of every query on next view.
- **PostgreSQL can't `SELECT DISTINCT` rows with a JSON column.** The snapshot path added
  `snapshots.diversity_meta` (JSON), which broke `FetchService#delete_extra_web_requests`; it now
  uses a subquery. Any new `DISTINCT` over `snapshots.*` has the same problem.

## 5. Open points

- The snapshot-based path (`ComputeSnapshotDiversityJob`, `snapshots.diversity*`, the **Result
  diversity** section of the embedder dialog) still exists for measuring an existing snapshot
  without changing the scorer. It now uses the same effective embedder. It overlaps with the
  scorer and could be removed, which would also drop the snapshot columns and endpoints.
- Per-result badges (current, pending, no title) in the comparison view are not built.
- Live results are scored only through the scorer; nothing marks which results are pending
  vectorisation.
