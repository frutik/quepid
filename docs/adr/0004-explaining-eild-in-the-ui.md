# ADR 0004 — Explaining an EILD score in the UI: components and near-duplicate pairs

- **Status:** Proposed
- **Date:** 2026-10-29
- **Affects (when built):** `app/services/diversity_calculator.rb`, `app/services/result_diversity.rb`,
  `app/controllers/api/v1/case_diversity_scores_controller.rb`,
  `app/javascript/utils/scorer_runtime.js`, `app/javascript/utils/core_workspace_runtime.js`,
  `app/javascript/utils/query_scoring.js`, `app/javascript/controllers/qscore_query_controller.js`,
  `app/javascript/controllers/search_result_controller.js`, `app/services/javascript_scorer.rb`
- **Builds on:** [ADR 0003](./0003-eild-expected-intra-list-diversity.md), §2.5 (the split of a
  score into grades and similarity, derived but not built)

---

## 1. Context

An EILD score is one number. When it is low, the person tuning the search cannot tell whether to
rate more results, retrieve better ones, or remove near-duplicates. ADR 0003 §2.5 shows the number
splits exactly into a grade part and a similarity part, and into per-pair contributions. Nothing
in the UI shows either, because nothing carries more than a number from the calculator to the
screen:

- `DiversityCalculator.eild` returns a `Float`.
- `POST api/cases/:id/diversity/score` returns `{ score, embedded }`.
- A scorer resolves with a number (`resolveScore(value)`), and `scoreQuery` returns
  `{ score, maxScore, allRated, countMissingRatings, backgroundColor }`.

This ADR decides how to carry the breakdown through, and what to show. It is a design only.

## 2. Decision

### 2.1 What is shown

Two views, built on one payload:

1. **Score breakdown** on a query's score: a bar that is the full 1.0, split into the score
   (`M × D̄`), the share lost to grades (`1 − M`) and the share lost to near-duplicates
   (`M × (1 − D̄)`), with M and D̄ as numbers. A one-line reading under it names the larger loss.
2. **Near-duplicate markers** on results: a result that is close to a higher-ranked one gets a
   badge ("≈ #2", with the similarity in its tooltip). Only the few pairs that lose the most are
   marked.

Not decided here, left as follow-ups: a case-level average of M and D̄, ΔM / ΔD̄ in the snapshot
compare header, and a pair heatmap. They reuse the same payload but each has its own cost (see §4).

### 2.2 The calculator returns a breakdown

`DiversityCalculator.eild` keeps returning a number. A new `DiversityCalculator.eild_breakdown`
does the same walk and returns:

```ruby
{
  score:     0.31,        # equals eild(...)
  relevance: 0.62,        # M = C · Σ disc(k) · rel(k)
  diversity: 0.50,        # D̄ = score / M   (nil when M is 0)
  pairs:     [ { a: 1, b: 2, weight: 0.08, distance: 0.03, loss: 0.0776 }, ... ]
}
```

- `a` and `b` are ranks counted from 1, `a < b`. `weight` is the pair's total share of M (both
  directions of the asymmetric formula added together). `distance` is the cosine distance.
  `loss = weight × (1 − distance)`, the part of M that this pair's closeness costs.
- `pairs` is cut to the top few by `loss` (5). Its size is bounded so the payload stays small.
- `eild` is implemented as `eild_breakdown(...)[:score]`, so there is one formula, and a test
  asserts the two never disagree.
- The skipped-term case from ADR 0003 §2.5 (a result with relevance 0, or only irrelevant
  neighbours, has no term) is reported as `skipped: [ranks]`. D̄ is computed from the terms that
  exist, so it does not read low for that reason. M is still the full grade part.

ILD has no grades and no ranks, so it gets no breakdown.

### 2.3 The endpoint returns it

`POST api/cases/:id/diversity/score` adds `breakdown` to its response when `metric` is `eild`:
`{ score, embedded, breakdown: { relevance, diversity, pairs, skipped } }`. The pair ranks refer to
the order of the posted `docs`, which is the order on screen, so the browser can map them to
documents by position. No new endpoint and no new request: the breakdown comes from the same
computation as the score.

### 2.4 The browser keeps it beside the number

A scorer resolves with a number, and scorers are user-written code, so the contract
`resolveScore(number)` does not change. The breakdown travels beside it:

- `diversityScore` in `scorer_runtime.js` receives the response, resolves the score as it does
  now, and stores the breakdown in a runtime variable for that scoring call, `details`.
- `scorer.score` returns the number as before. A second function, `scorer.lastDetails(queryId)`,
  returns the stored breakdown. It is overwritten by the next call for the same query, so it
  always matches the latest score.
- `scoreQuery` (`query_scoring.js`) reads it after the score resolves and adds
  `details` to its result: `{ score, maxScore, allRated, ..., details }`. `details` is `null` for
  every scorer that does not provide one, so existing consumers are unaffected.
- `qscore_query_controller` reads `details` from the same store it already reads the score from.

Why beside the number and not inside it: scoring has several consumers that expect a number (case
average, score history, snapshots, CSV export). Changing what a scorer resolves with would touch
all of them. A `details` field on the result object, which is already an object, touches none.

### 2.5 The server-side scorer is unchanged

`FetchService` and `JavascriptScorer` score snapshots on the server and need only the number, so
they keep using `ResultDiversity#score`'s value. The breakdown is computed only where it is shown,
for the live query. This means snapshots do not carry M and D̄ (see §4).

### 2.6 Where it renders

- **Breakdown:** a popover on the query's score badge (`qscore_query_controller`), opened by click,
  like the existing score badge interactions. A Stimulus controller builds it from `details`:
  the three-segment bar, the two numbers, and the reading. When `details` is `null` (any other
  scorer) there is no popover and nothing changes.
- **Markers:** `search_result_controller` already renders one result. It receives the pair list for
  its query, and a result at rank `b` of a listed pair shows the badge for the pair with the
  largest `loss`. The badge shows "≈ #a"; the tooltip shows the similarity (`1 − distance`) and
  the share of M lost.
- **Language:** the reading is a fixed set of sentences chosen by comparing `1 − M` with
  `M × (1 − D̄)`: mostly grades, mostly near-duplicates, or neither dominates. Numbers are shown
  to two decimals, matching the score.

### 2.7 When there is nothing to explain

No breakdown, and no popover or badges, when: the scorer is not EILD; the score is null (fewer than
two results with a title); the embedding call failed; or M is 0 (nothing is rated, so there is
no D̄). In the last case the popover says "No rated results in the top N", which is the actual
cause of the zero.

## 3. Options considered

- **Return the breakdown as the scorer's value** (an object instead of a number). Rejected: every
  consumer of scores expects a number (§2.4).
- **Compute the breakdown in the browser** from the vectors. Rejected: the browser never receives
  vectors, and sending them would be large and exposes the embedder's output for no other reason.
- **A separate endpoint for the breakdown.** Rejected: it would repeat the lookup and the
  computation, and could disagree with the score for a moment while ratings change.
- **Show the full pair list or a heatmap.** Deferred: the top pairs answer "which results" and
  stay small; a heatmap needs the full matrix in the payload (10 × 10 for the default depth, 100 ×
  100 at the maximum).
- **Store M and D̄ on snapshots** for the compare view. Deferred (§4).

## 4. Consequences

- One extra object per live EILD score response, a few hundred bytes. No extra embedding calls.
- The popover and badges exist only for the live query. A snapshot's score has no breakdown,
  so the compare header cannot show ΔM and ΔD̄ without a schema change (`snapshot_queries` would
  need `relevance` and `diversity` columns beside `diversity`, and `FetchService` would call
  `eild_breakdown`). That is a separate decision.
- A case-level average of M and D̄ would be the mean of the per-query values held in the score store,
  with the same caveat as any averaged score: queries with no score are left out.
- `details` is now part of the score result shape. Anything that spreads or serialises it (CSV,
  history) must ignore it or be told; tests cover the existing consumers.
- The formula lives in one place (`eild_breakdown`), and `eild` is derived from it, so the
  explanation cannot drift from the score.

## 5. Tests

- Calculator: `eild_breakdown[:score]` equals `eild` on random lists (the 200-list check from ADR
  0003 §2.5 becomes a test); `relevance × diversity` equals `score`; the pair `weight`s over all
  pairs sum to `relevance`; the skipped ranks are reported.
- Controller: `breakdown` present for `metric: eild`, absent for `ild`.
- Runtime: `details` is stored for EILD, `null` for ILD and for scorers that never call it; the
  number is unchanged.
- `scoreQuery`: `details` passes through; consumers that ignore it are unaffected.
- Browser: popover opens on a query with an EILD scorer and not on others; the badge shows on the
  lower-ranked member of the top pair.

## 6. Open points

- Whether `pairs` should be cut at 5 or by a minimum `loss`.
- Whether the badge should also appear in the snapshot result view, which would need pairs stored
  with the snapshot.
- The wording of the reading when custom rating scales do not start at 0 (ADR 0003 open point),
  where the lowest grade still counts as some relevance.
