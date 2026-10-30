# Pairwise and BlitzRank ranking judges — implementation plan

> **Status:** P1–P5 implemented (adapter, cache, oracle, rankers, metrics, rake harness); P0 (live Jev check), G1 and everything after not done. **Decision record:**
> [ADR 0005](../adr/0005-pairwise-and-listwise-ranking-judges.md) — why a ranking judge is separate
> from the pointwise one, why BlitzRank is gated, what is rejected. This file is the *how*.
> **Pitch:** [pairwise_judges_elevator_pitch.md](pairwise_judges_elevator_pitch.md).
>
> **Precondition:** judge calibration (`feature/judge-calibration`, PR #1827; ADR 0002 on
> `relevance-factory-adrs`) is on `main`. Every file named below under "calibration" is read from that
> branch (`app/models/calibration_*.rb`, `app/jobs/calibration_run_job.rb`,
> `app/services/judge_agreement.rb`, `app/services/calibration_score_impact.rb`). **Re-read the merged
> versions before starting; this plan was written against `d58d42b77`.**

## 0. The question, and the rules

**Question:** on the same human-rated queries, does a pairwise Jev ordering agree with humans better
than the ordering implied by Jev's pointwise grades — and only then, can BlitzRank make it cheaper
without losing that?

Rules every step obeys (inherited from ADR 0001 §5.1, plus ours):

- **R1 — Ratings are never written.** No step creates, edits or deletes a `Judgement`, and nothing
  calls `RatingsManager`. A ranking result is not a rating (ADR 0005 D1).
- **R2 — `LlmService`'s public surface and its tests, `RunJudgeJudyJob` and its tests, stay green
  without edits.** Needing to edit them means a step changed pointwise behaviour.
- **R3 — Comparison builders are inert** (ADR 0001 B1–B4): no I/O, no clock, no randomness,
  JSON-serialisable, parsed Hash in, never saves.
- **R4 — Additive and revertable alone.** New files and tables; each step is one PR.
- **R5 — The bar is fixed before the experiment (§4).** Not after.
- **R6 — "Order", never "rating"** in any UI string, column or class name for ranking results.

## 1. What we build on

| Piece | Where | Used for |
| --- | --- | --- |
| Adapter seam, `request_envelope` / `apply_response`, scale as criteria | `app/services/llm_judge_adapters/{base,jev}.rb` | the pattern `comparison_envelope` / `apply_comparison` copies |
| Jev `choice` question, 4,000-char field cap, 80k-char state cap | `LlmJudgeAdapters::Jev` | per-document truncation and state shaping are reused as-is |
| Provider capability flags (`images?`, `batch?`) | `LlmProviders` registry | new `pairwise?` flag |
| `LlmConnection` (Faraday, retry on 429/529) | `app/services/llm_connection.rb` | transport |
| Frozen samples, query-sampled top-N, reference ratings | `CalibrationSample`, `CalibrationSamplePair` (`QUERY_DEPTH`) | the evaluation set, same for every arm |
| Runs, answers kept apart from judgements, snapshot of judge settings | `CalibrationRun`, `CalibrationAnswer`, `CalibrationRunJob` | run lifecycle, cancel, progress broadcasts |
| Agreement and rank metrics | `JudgeAgreement`, `CalibrationScoreImpact` | pointwise arm unchanged; nDCG@10 helper reused |
| Calibration tab, results page, new-run dialog | `app/views/calibrations/*`, `calibration_dialog_controller.js` | where results show |

## 2. Data model (one migration, step 1)

All tables kept apart from judgements. Names follow R6.

```
preference_comparisons            # the cache (ADR 0005 D2)
  judge_id            -> users (AiJudge), cascade
  rubric_version      string       # hash of the instructions + scale text sent; new rubric = new rows
  query_text / query_doc_pair_a_id / query_doc_pair_b_id -> query_doc_pairs, cascade
                                   # a_id < b_id always: one row per unordered pair
  presented_first     string       # 'a' | 'b' — which one the model saw first
  winner              string       # 'a' | 'b' | 'tie'   (after un-swapping)
  probability         float        # of the winner, 0.5..1.0
  confidence          float        # Jev's own, if reported
  input_tokens / output_tokens integer
  unique (judge_id, rubric_version, a_id, b_id)

order_runs                        # one ranking judge over one sample
  calibration_sample_id, judge_id, created_by_id, status, strategy,
  judge_snapshot json, comparisons_count, error, started_at, finished_at

order_results                     # one ranked query
  order_run_id, query_text, ordered_pair_ids json, comparisons_used,
  calls_used, tokens_used, complete boolean
```

`strategy` is `round_robin` | `comparison_sort` | `blitzrank`. A pair is `(query_doc_pair)`; every
comparison is between two pairs **of the same query**, never across queries.

*Decision for the implementer:* `order_runs` could instead be a `kind` on `calibration_runs`. Prefer
the separate table unless the merged calibration code makes the reuse trivial — `CalibrationAnswer`
is per-pair with a rating, and an order result is per-query without one, so sharing the table would
need nullable columns throughout.

## 3. Steps

Each step is one PR, deployable alone, in this order. **G1 and G2 are decision gates: stop there if
the answer is no.**

### P0 · Verify the two Jev facts the design leans on *(no code in `app/`)*

Against the live API, with a scratch script in the scratchpad (not committed):

1. A `choice` question over two options returns `probabilities` for both. Is there a usable
   tie — a third option, or only a near-0.5 probability? (ADR 0005 §4.1.)
2. Does a request with several questions (`"c1".."c20"`) return one answer each, and is the `state`
   shared? (ADR 0005 §4.2.) If the state is shared the query goes in `state` and each question
   carries its own two documents in `instructions`/`criteria`; if not, one request per comparison.
3. Position bias: ask the same pair in both orders for ~30 pairs and count flips. Record the number
   in the ADR as evidence for D3's swapping.

*Output:* a short appendix on ADR 0005 with the verified request/response shape. If (1) shows no
tie signal, define `tie` as `probability < TIE_BAND` and make `TIE_BAND` a judge option.
*Rollback:* nothing shipped.

### P1 · Pairwise adapter operation and `pairwise?` flag

- `LlmProviders`: add `pairwise?` (true for `typesafe_jev` only); test asserts it, like B6.
- `LlmJudgeAdapters::Base`: `comparison_envelope` raises `NotImplementedError`-style
  `"#{self.class} cannot compare"`; `apply_comparison` likewise.
- `LlmJudgeAdapters::Jev#comparison_envelope(query, doc_a, doc_b, system_prompt:, swapped:)`:
  - `state`: `{ query:, information_need: }` (compact), documents truncated with the existing
    `truncated_fields`, under `MAX_STATE_CHARS`.
  - one `choice` question, criteria = the two documents' labels, instructions = the judge's prompt
    plus "which is more relevant to the query". The scale is **not** sent: a comparison needs no scale.
  - `swapped:` is an argument, computed by the caller (R3).
- `Jev#apply_comparison(body, swapped:)` → `{ winner:, probability:, confidence:, tokens: }`, with
  the swap undone. A malformed answer returns `winner: nil`, same defensive reading as `numeric_value`.
- `PairwiseSwap.for(query_text, pair_a_id, pair_b_id, rubric_version)` → `true/false`, from a stable
  hash (`Digest::SHA256`), roughly half each. Pure.

*Tests (webmock, no live calls):* envelope is deterministic and `JSON.parse(to_json)` round-trips
(B1/B2); `apply_comparison` on a canned Hash, no HTTP (B3); never saves (B4); swap un-done correctly
for both values; swap distribution is ~50/50 over a few thousand ids; a non-pairwise provider raises.
`llm_service_test.rb` and job tests unchanged (R2).
*Rollback:* revert.

### P2 · Comparison cache and the oracle

- Migration for `preference_comparisons` (§2 — only this table in this step).
- `PreferenceComparison` model: uniqueness, `winner` inclusion, a scope `for(judge, rubric_version)`.
- `PairwiseOracle.new(judge:, rubric_version:)#compare(pair_a, pair_b)`:
  1. normalise so `a_id < b_id`; read the cache; return it if present;
  2. otherwise build the envelope (`PairwiseSwap`), post through `LlmConnection`, `apply_comparison`,
     insert, return.
  Memoise nothing in the process; the table is the cache. Concurrent inserts of the same row rescue
  `RecordNotUnique` and read the winner.
- `rubric_version` = digest of (judge prompt, model, Jev instructions template). Changing the prompt
  therefore starts a fresh cache rather than silently mixing.

*Tests:* second call hits the cache (no HTTP); order-insensitive (`compare(a,b)` == flipped
`compare(b,a)`); unique-violation race; different rubric → different rows.
*Rollback:* drop the table and class; nothing references them yet.

### P3 · Rankers: round-robin and comparison sort

`app/services/pair_ranking/` — pure objects over an oracle, so they are tested with a hash of
known preferences and no database.

- `RoundRobin#rank(pairs)` → `{ order:, comparisons:, cycles: }`. Wins counted, ties 0.5 each;
  break remaining ties by the search's original order (deterministic). `cycles` counts 3-cycles found
  so stability reporting can use it.
- `ComparisonSort#rank(pairs)` → merge sort with the oracle as comparator; `tie` keeps original
  order. About `n log n` calls; cache makes repeats free.
- Both take the **candidate order as given** (the search's order) and are deterministic for a given
  oracle answer set.

*Tests:* a perfect oracle gives the true order for both; an oracle with a planted cycle terminates and
reports it; call counts: round-robin is exactly `n(n-1)/2`, comparison sort ≤ `n⌈log₂n⌉`; reversing
the input of a consistent oracle gives the same order.
*Rollback:* revert.

### P4 · Offline experiment harness *(no UI)*

A rake task `judges:rank_sample[sample_id,judge_id,strategy]`, wrapping the above and `order_runs` /
`order_results` (migration here). It:

1. loads the sample's queries and their top-N pairs;
2. ranks each with the chosen strategy through `PairwiseOracle`;
3. writes `order_results`, with calls, tokens and wall time;
4. prints the §4 metrics against the sample's reference grades, next to the pointwise arm.

Look at the numbers, and a handful of disagreements by eye, before building any UI. The rake task is
the whole deliverable of this step.

*Rollback:* drop the two tables and the task.

### P5 · Metrics

`app/services/order_agreement.rb`, pure, no database, given `[ { reference_grade:, position: } ]` per
query. Each is a method returning a number or `nil` when undefined:

- `pairwise_accuracy` — over pairs with different reference grades; a judge tie counts as half.
- `kendall_tau_b` — tie-aware, between judge position and reference grade. Reference ties are real
  (many pairs share a grade), so τ-a would be wrong here.
- `ndcg_at(k = 10)` — gains from reference grades, order from the judge. Reuse the nDCG helper in
  `CalibrationScoreImpact` rather than writing another.
- `top_k_overlap(k = 10)` — against the reference's top k by grade (ties at the cut-off included, and
  documented as such).
- `stability` — takes two orders of the same list and returns τ-b between them; the harness runs the
  strategy twice (candidates reversed the second time) and passes both.
- Aggregation across queries: macro-average, with the per-query values kept for the table.

*Tests:* hand-computed small cases; reversed list gives τ-b = −1; all-tied reference gives `nil`, not 0;
nDCG matches `CalibrationScoreImpact`'s value on the same grades and order.
*Rollback:* revert.

### G1 · Gate — did pairwise earn it?

Run P4 on at least two books with human-rated, query-sampled calibration samples (as many queries as the
calibration minimum of `CalibrationScoreImpact::MIN_QUERIES`, 10, allows; more if the humans have
rated them). Compare, per ADR 0005 D5: pointwise Jev ordering, pairwise round-robin, and the
search's own order as the floor.

**The bar (fixed here, §4).** Proceed only if pairwise round-robin beats pointwise Jev on **both**
τ-b and nDCG@10 against humans, by more than the run-to-run noise measured by `stability` and by the
spread between the two books, **and** the human-vs-human ceiling (§4) shows the reference is
trustworthy. If not: write up the result as an addendum to ADR 0005, mark the ADR *Deprecated*, and
stop. P6 onward is not built.

### P6 · Ranking calibration in the UI

Only after G1 passes.

- `OrderRunJob`, modelled on `CalibrationRunJob`: queued → running → done / cancelled / failed, cancel,
  Turbo progress, `limits_concurrency`. One job per run; queries processed in order; comparisons
  within a query may be issued concurrently up to the provider's limit (Jev: 1,200 req/min — a
  setting, not a constant).
- Calibration tab: **New calibration** gets a *"Ranking judge (beta)"* choice, shown only for judges
  whose provider is `pairwise?`. The dialog states the number of calls, as the existing dialog does
  (`n(n−1)/2` per query for round-robin).
- Results page: the §4 metrics as cards, an arms table (pointwise / pairwise), per-query rows with the
  two orders side by side and the reference grades, and the list of **pairs the pairwise judge
  and the reference disagree on**, to read. Copy says *order*, never *rating* (R6).
- Re-run on the **same frozen sample** with a changed prompt or rubric, as calibration already allows.

*Tests:* job lifecycle and cancel mirror `calibration_run_job_test.rb`; controller test for the new
choice (hidden for non-pairwise judges); a system/manual scenario added to
`docs/manual-testing/12-ai-judges.md` and `tracking.yml`.
*Rollback:* revert the UI and job; the offline harness from P4 still works.

### G2 · Gate — is BlitzRank worth building?

Using the numbers from P6 on real books, answer in writing:

1. How many oracle calls did round-robin and comparison sort use per query, and what did they cost on
   Jev? (Tokens are recorded in `preference_comparisons`.)
2. Does comparison sort lose quality against round-robin? If not, it is the cheaper answer already.
3. Is the remaining saving BlitzRank could offer — over comparison sort, at our list sizes (10–20) —
   material in money or wall time?

If comparison sort holds quality and the cost is already trivial, **stop here and keep it.** Record it
in ADR 0005. BlitzRank proceeds only if the saving is real *and* the target is deeper lists (≥ 50) or
a pricier model.

### P7 · BlitzRank *(only past G2)*

Open question 3 of the ADR becomes the first task: read BlitzRank's source and licence, and determine
whether its loop can run on a binary oracle and whether its top-k mode accepts it.

Choose one integration, in this order of preference, and record the choice in the ADR:

1. **Port the algorithm to Ruby** as a third strategy beside `RoundRobin`/`ComparisonSort`, if the core
   is small and the licence permits. No new runtime, tested like P3.
2. **Sidecar:** a small Python process that asks Quepid for comparisons (HTTP to a cache-backed
   endpoint) and returns an order. Only if (1) is impractical; it adds a service to deploy, and
   `Dockerfile.prod` and the docker-compose files change.
3. **Listwise oracle on a chat provider**, where BlitzRank's k-wise calls are what it was built for: an
   adapter operation `ranking_envelope(query, docs[k])` for OpenAI/Anthropic. A separate plan; do not
   start it inside this one.

*Tests:* as P3, plus a planted-cycle oracle; plus the property that BlitzRank's order equals
round-robin's on a consistent oracle.
*Gate to merge:* on the P6 data, BlitzRank's τ-b and nDCG@10 are within noise of round-robin's, with
the call count it was built to reduce, measured. Otherwise do not merge.

### P8 · Pairwise disagreement detector *(deferred; its own ADR)*

Uses the cache from P2 and pointwise grades. Candidates: equal pointwise grades with a strong pairwise
preference; opposite order; cycles. Output feeds escalation (`docs/todo/escalating_judges.md`) as "send
these to a second judge or a human". Not planned further here, and the only step in this document that
could ever influence a judgement — through escalation, never by writing a rating (R1).

## 4. The experiment, fixed before it runs

**Reference.** Human grades on the frozen, query-sampled calibration sample. Pairs the humans rated
unrateable or `judge_later` are excluded, as calibration already excludes them.

**Human ceiling.** Where two or more humans rated the same pairs, compute their agreement on
preferences (ADR 0005 D7). A judge cannot sensibly be asked to beat it. If the books have no
multiply-judged pairs, say so in the result; do not invent a ceiling.

**Arms, on the same sample:** search order (floor) · pointwise Jev (existing) · pairwise Jev, round-robin ·
(later) comparison sort · (later) BlitzRank.

**Metrics:** the five in P5, plus calls, tokens and wall time per query.

**Pass condition at G1:** written down *with its numbers* in the PR that introduces P4, before any
result exists. This plan deliberately does not choose the thresholds: they depend on the human ceiling
and noise level of the books we have, which we do not yet know. What it fixes is the rule — both τ-b
and nDCG@10, better than pointwise by more than the measured noise.

**Not claimed:** that a better ordering means better grades. A pairwise win here is a win at
reordering.

## 5. Risks

| Risk | Handling |
| --- | --- |
| Position bias — the model favours whichever it sees first | deterministic per-pair swap (P1); `stability` metric (P5); P0.3 measures it first |
| Intransitive answers (A > B > C > A) | `cycles` reported by the rankers; round-robin tolerates them by counting wins; P8 uses them as a signal |
| Cost: round-robin at 20 results is 190 calls a query | the dialog states the call count; cache makes re-runs free; comparison sort (P3) is the fallback |
| Rubric drift mixes old and new answers in the cache | `rubric_version` is part of the unique key (P2) |
| "Order" read as "rating" by users | R6; results page never offers a "use as ratings" action |
| Reference grades are too noisy to tell the arms apart | human-ceiling check at G1; stop instead of reading noise |
| Calibration code changes before it merges | precondition re-read; P4 and P5 depend on its sample and nDCG helper only |
| Jev's comparison API differs from what the PDF implies | P0 before any code |

## 6. Out of scope

Writing grades from rankings; replacing or changing the pointwise judge; the OpenAI Batch path
(ADR 0001); image documents in comparisons (`jev_image_support.md` — text only here); the
disagreement detector (P8); a "rank this book's queries" feature for ordinary users.

## 7. Definition of done

P0–P5 and G1 form the experiment, and it is complete when the G1 result is written into ADR 0005 as an
addendum, with the numbers, whichever way it went. P6 and everything after exist only if G1 passed.
