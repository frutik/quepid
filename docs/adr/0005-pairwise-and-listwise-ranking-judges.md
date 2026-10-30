# ADR 0005 — Pairwise and BlitzRank judges: a ranking judge beside the pointwise one, measured by calibration

- **Status:** Proposed
- **Date:** 2026-10-30
- **Affects:** `LlmJudgeAdapters` (a second operation pair), a new ranking-judge service and cache
  tables, calibration runs/metrics. `RunJudgeJudyJob`, `Judgement`, `RatingsManager` and the scorers
  are **not** touched.
- **Builds on:** [ADR 0001](./0001-llm-judge-provider-architecture.md) (the adapter seam, the inert
  request envelope, Jev as a provider). Depends on judge calibration, which is on
  `feature/judge-calibration` / open PR #1827 and described by ADR 0002 on `relevance-factory-adrs`.
  Neither is on `main` yet: **this ADR must not start before calibration lands.**
- **Plan that implements this:** to be written as `docs/todo/pairwise_ranking_judges.md` once this is
  accepted. The one-page pitch is [`docs/todo/pairwise_judges_elevator_pitch.md`](../todo/pairwise_judges_elevator_pitch.md).
- **Source:** the "Explain Pairwise Ranking" discussion of a post about using Jev as a cheap
  preference oracle for BlitzRank. Its claims about BlitzRank (25–40% fewer tokens, ~7× fewer than
  pairwise methods) are the BlitzRank authors' results on *their* models; nothing here has been
  measured on Jev or on Quepid books.

---

## 1. Context

### 1.1 What we have

An AI judge rates **one query/document pair at a time** on the book's scale (pointwise). Jev
(ADR 0001) is the cheap, fast, typed provider for it: it returns a `score` over the scale's levels,
a probability distribution and a confidence. Calibration (ADR 0002) lets us run one judge on a
frozen sample of pairs another judge already rated and compare the two: Krippendorff's α, a confusion
matrix, and — when the sample is drawn by query — nDCG@10 and Kendall's τ over each query's top list.

### 1.2 The new idea, and the trap in it

Jev also answers a different question: *"for this query, which is more relevant, A or B?"* — a
`choice` question with a probability. Pairwise preferences are attractive because they are easier to
get right than an absolute grade and cheap to ask. **BlitzRank** is an algorithm that turns such
comparisons (or k-wise rankings from a chat model) into a full ranking with fewer calls than
comparing every pair, by keeping a preference graph, inferring by transitivity, and tolerating
cycles.

The trap: **a ranking is not a set of relevance judgements.** Knowing A > B > C > D says nothing about
whether A and B are both perfect, or both bad with A slightly less so. nDCG needs graded labels, and
there is no legitimate way to read a 0–3 grade off a rank position without an extra assumption. A
ranking judge therefore answers a *reranking / ordering* question; the existing judges answer a
*relevance* question. The two get conflated easily, and conflating them would silently corrupt
Quepid's ratings.

### 1.3 Forces

- We do not yet know whether pairwise preferences from Jev agree with humans **better** than Jev's
  pointwise grades do. If they do not, BlitzRank cannot fix that — it only makes a bad oracle
  cheaper to query.
- With 10–20 candidates per query, an exhaustive pairwise baseline is 45–190 calls per query. At
  Jev's price and 1,200 req/min that may already be cheap enough that BlitzRank's savings do not
  matter. BlitzRank's published savings come largely from **k-wise** calls to a chat model; Jev's
  interface is binary, which collapses BlitzRank to its k = 2 case. (Our inference, to be tested.)
- BlitzRank is a Python package (`pip install blitzrank`). Quepid is Rails. Anything that depends on
  it is a cross-language integration.
- Calibration already gives us the comparison harness: frozen samples (same pairs, re-runnable),
  stored answers kept apart from judgements, and rank metrics. We should extend it, not build a
  second evaluation subsystem.

---

## 2. Decision

**We add a ranking judge as a second kind of judging, alongside the pointwise judge. It is
built in the order pairwise → measure → BlitzRank, evaluated entirely through calibration, and in this
ADR's scope it never writes a `Judgement` or changes a book's ratings.**

### D1 — A ranking judge answers "what order?", not "what grade?"

Its output is a **ranking** (or a set of preferences) over one query's candidate documents. It is not
converted to 0–3 grades, by position or any other rule. Grades remain the job of the pointwise
judge and of humans. When a ranking is scored with nDCG, the gains come from the **reference's
grades** (human, or an existing judge); the ranking judge supplies only the order.

*Rejected:* mapping rank to grade (top 2 → 3, next 3 → 2, …). It invents a calibration the ranking
never contained, and it would feed `RatingsManager` numbers no judge ever gave.
*Rejected:* a "ranking" mode on the existing judge writing `Judgement` rows. It breaks the
one-judgement-per-(judge, pair) invariant and the meaning of every scorer downstream.

### D2 — Ranking results live apart from judgements

New storage, modelled on calibration answers (ADR 0002 C3 — "answers are stored apart from
judgements, so a calibration never moves a rating"):

- a **comparison cache**: one row per (judge, rubric version, query, pair A, pair B), holding the
  winner (`a` / `b` / `tie`), its probability, whether presentation order was swapped, and token
  usage. A comparison already in the cache is never asked again.
- a **ranking result**: one row per (run, query), the resulting order, and the number of
  comparisons / calls / tokens it took.

Judges, scales and books are not edited. Deleting a book or judge cascades, as calibration's tables do.

### D3 — Pairwise is a second operation pair on the adapter seam, and keeps ADR 0001's contract

The adapter gains `comparison_envelope(query, doc_a, doc_b, …)` and
`apply_comparison(response_body)` with the same rules as `request_envelope` / `apply_response`
(batch-readiness B1–B4): the envelope is inert, deterministic, JSON-serialisable; the response is a
parsed Hash; nothing saves. Two consequences:

- **Order randomisation must be deterministic.** LLM judges favour a position, so A/B order must
  alternate — but B1 forbids randomness in the envelope. The swap is derived from a stable hash of
  (query, pair ids, rubric version), and recorded in the cache row so it can be undone when reading.
- Only providers that can express a comparison implement it. Jev does (a `choice` question with its
  probabilities, and the up-to-20-questions-per-request batching, which must be verified against
  the API before relying on it). OpenAI/Anthropic implement it later, if at all. A registry flag
  (`pairwise?`, like `images?`/`batch?`) keeps providers that do not out of the picker — data, not a
  branch.

The pointwise path, `LlmService`'s public surface and its tests stay unchanged (ADR 0001 D2).

### D4 — The ranker is separate from the oracle

A ranker takes an **oracle** ("compare these two", or "rank these k") and a list of candidates, and
returns an order plus its call count. Strategies, all behind one interface:

1. **Round-robin / Copeland** — compare every pair, rank by wins. The exhaustive baseline.
2. **Comparison sort** — cache-aware, O(n log n) calls. Cheap, ignores cycles.
3. **BlitzRank** — preference graph with transitive inference, top-k aware, cycle tolerant.

(1) and (2) are small, pure Ruby and are built first: they make the pairwise judge measurable and are
the honest baseline BlitzRank must beat on calls *at equal quality*. **BlitzRank is a later,
separately gated step** (D6), and the integration shape — a Ruby port of the algorithm, or a sidecar
that calls back into the comparison cache — is decided then, once we know whether it earns its
keep. We do not commit to a runtime dependency on a Python package in this ADR.

### D5 — Measurement is a ranking calibration, on the frozen query sample

Calibration samples **by queries** (each query's top-N pairs) and stores a frozen reference. A ranking
run is the same flow with a different judge type: each sampled query is ranked, and the result is
compared with the reference grades. The same frozen sample is used for three arms, so they are
directly comparable:

| Arm | Output | Compared how |
| --- | --- | --- |
| Pointwise Jev (exists) | grades → order | existing α / confusion / nDCG@10 / τ |
| Pairwise Jev, round-robin | order | the rank metrics below |
| Pairwise Jev, BlitzRank (later) | order | same, plus calls saved vs round-robin |

Metrics, all computed against the **human** reference (the PDF's list, kept):

- **Pairwise accuracy** over pairs the humans graded differently (ties in the reference excluded).
- **Kendall's τ-b** between the judge's order and the human order, tie-aware. (`CalibrationScoreImpact`
  already carries a τ for query orderings; this is a different τ — per-list — and is a new computation.)
- **nDCG@10 of the judge's order, gains from human grades**, beside the nDCG@10 of the pointwise
  judge's order and of the original search order.
- **Top-10 overlap** with the human top 10.
- **Cost per query**: calls, tokens, latency.
- **Stability**: rank the same query with the candidate list reversed, and again a second time;
  report how much the order moves.

**Decide the bar before running.** The question this ADR exists to answer is whether pairwise beats
pointwise Jev on τ-b and nDCG@10 against humans on the same sample. The numeric thresholds are set
in the plan, before any run, so the result cannot be fitted afterwards.

### D6 — BlitzRank is gated on pairwise earning it

Order of work, each step shippable alone and each a decision point:

1. **Calibration lands on `main`.** Not ours to build; a precondition.
2. **Pairwise judge + cache + round-robin ranker, offline** (no UI, console/rake). Look at the data.
3. **Ranking calibration** (D5) in the Calibration tab. Answer the research question.
   *Gate: if pairwise does not beat pointwise Jev against humans, stop. BlitzRank is not built.*
4. **Cheaper rankers**: comparison sort; then BlitzRank (and, optionally, a *listwise* oracle on a
   chat provider, where k-wise calls are what BlitzRank is actually designed for).
   *Gate: only if the call/cost saving over round-robin is material **and** quality is unchanged.*
5. **Pairwise disagreement detector** (deferred, separate ADR): flag pairs where the pairwise
   judge and the pointwise grades contradict (equal grades but a strong preference; opposite order;
   cycles) as candidates for a second judge or a human. This is where pairwise could *improve*
   Quepid's existing ratings rather than just produce another ranking, and it is the only place a
   ranking judge would influence judgements — through escalation, never by writing grades.

### D7 — Agreement between the two judge types is defined on preferences

Pointwise and pairwise judges cannot be compared with α on grades, since one produces none. The
common currency is the **preference**: a pointwise judge's grades imply "A > B" for any two pairs
graded differently, and equal grades imply no preference. Agreement between any two judges, of
either kind, on a query is the share of implied preferences they agree on, plus τ-b. This also
gives the human-vs-human ceiling: if two humans do not agree with each other on preferences,
neither judge type can be expected to.

---

## 3. Consequences

**Positive**

- We find out cheaply, and before building BlitzRank, whether pairwise preferences are a better signal
  than pointwise grades. Either answer is useful.
- Ratings, scorers and the judging job are untouched, so the existing judges keep their guarantees.
- Calibration's frozen samples make arms comparable and re-runnable (new prompt, new rubric, new
  model) without new evaluation infrastructure.
- The comparison cache turns repeated experiments into near-free re-reads and gives a durable
  preference graph for the disagreement detector.

**Negative**

- A second judging concept in the product (rank vs. rate) to explain and to keep from being
  confused: the UI must say "order", never "rating", for ranking results.
- New tables, and an adapter interface that is now two operation pairs rather than one.
- Pairwise judging is O(n²) in the worst case; the round-robin baseline costs more calls than
  pointwise at the same depth (45 vs. 10 for n = 10). If Jev is cheap that is acceptable; it must
  be measured, not assumed.
- Position bias, ties and non-transitive judgements are real and add noise the pointwise path does
  not have; D3's swapping and D5's stability metric exist to expose them, not to eliminate them.

**Neutral / accepted**

- A ranking judge cannot replace human or pointwise grades for nDCG. It can only reorder, and it is
  measured as a reorderer.
- BlitzRank may turn out unnecessary at Quepid's list sizes with Jev's pricing. That is an
  acceptable outcome of the gate, not a failure of the plan.

## 4. Open questions

1. Does Jev's `choice` question support a position-neutral tie, or must "tie" be inferred from a
   near-0.5 probability? Check against the API before D3's envelope is fixed.
2. Does Jev really accept up to 20 questions per request, and what does that do to the state (the
   query is shared, the two documents are not)? Affects cost, not correctness.
3. BlitzRank's licence, current API and whether its core loop can be driven with a binary oracle
   — read it before D6 step 4, not now.
4. What list depth is the target: top 10, or 20? Round-robin at 20 is 190 comparisons a query.
5. Do we need a human-vs-human preference baseline on the sample (D7), and do the books we
   would test on have enough multiply-judged pairs to provide one?

---

## Appendix A — P0: what the live Jev API does (2026-10-30)

Run against the dev `jev` judge (`jev-1.14.0`, instructions = the judge's pointwise prompt), 15 queries
of the dev books, six documents each. Scratch script, not committed.

1. **Request/response shape (confirmed).** One `choice` question with criteria `{A, B}` returns
   `answers.<id> = { type: "choice", choice, confidence, probabilities: { A, B } }` and a top-level
   `usage: { input_tokens, output_tokens }`. The adapter's reading is correct, and tokens are reported.
   About 1,200 input tokens per comparison of two long documents.
2. **Ties.** A third option works: with criteria `{A, B, TIE}` Jev returns a probability for `TIE` too.
   So a tie can be asked for rather than inferred from a near-0.5 probability. Not yet tested whether it
   is *used* sensibly (the one probe put 0.25 on TIE for a pair where A won at 0.55). `jev_tie_band`
   stays as the fallback.
3. **Batching.** Several questions in one request (`c1`, `c2`) each get their own answer, and `state`
   is shared: the query and three documents (`A`, `B`, `C`) went in `state` once and each question asked
   about two of them. Input tokens for two questions were 2,315, so roughly the per-question cost of
   separate calls minus the shared query; the saving is calls, not tokens. A query's whole round-robin
   can be one request (up to the 20-question limit, unverified here).
4. **Position bias depends on the data.** On the first probe (dev books of long legal text, six
   documents a query) 30 pairs asked in both orders flipped 17–19 times (57–63%) and the document
   shown first won 47 of 60 answers. On the **Haystack Icecat Rating Party** book (book 4; Icecat product
   records; anonymous human ratings 0–3 averaged per pair), 30 pairs with a clear human preference
   (the best-rated against the worst-rated document of a query, mean rating at least 1.5 apart),
   in both orders:

   | Wording | first shown wins | flipped across orders | one answer agrees with humans | both orders agree |
   | --- | --- | --- | --- | --- |
   | `A`/`B`, the pointwise prompt | 33/60 | 3/30 | 49/60 (82%) | 23/30 |
   | `1`/`2`, a comparison-specific prompt | 34/60 | 4/30 | 50/60 (83%) | 23/30 |

   So the bias is not a property of Jev but of the documents: it is large on long, similar texts and
   negligible on short product records, and wording changed nothing. These are the *easy* pairs; the
   agreement on near-equal documents, which a ranking actually has to settle, is not measured. The
   anonymous ratings also mean this book cannot be a calibration reference as it stands (calibration
   samples need a named rater).

**Consequence for the plan.** Position bias must be measured per book, not assumed away: report the
flip rate with every run (it is `stability`, P5), and ask both orders and combine only where it is high.
The swap in D3 stays as the cheap default. G1 needs a book with a named human rater, and pairs that
are not just the extremes of a query.
