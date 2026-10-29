# ADR 0003 — EILD: rank- and relevance-aware result diversity, after Vargas & Castells (2011)

- **Status:** Accepted
- **Date:** 2026-10-28
- **Affects:** `app/services/diversity_calculator.rb` (`eild`), `app/services/result_diversity.rb`,
  `app/controllers/api/v1/case_diversity_scores_controller.rb`, `app/services/fetch_service.rb`,
  `app/javascript/utils/scorer_runtime.js` (`scoreByExpectedDiversity`), `app/models/scorer.rb`,
  `db/scorers/eild@10.js`
- **Builds on:** [ADR 0002](./0002-result-diversity-as-a-scorer.md) (ILD as a scorer)
- **Source:** Saúl Vargas and Pablo Castells, "Rank and Relevance in Novelty and Diversity Metrics
  for Recommender Systems", *RecSys '11: Proceedings of the fifth ACM conference on Recommender
  systems*, ACM, 2011, pp. 109–116, DOI [10.1145/2043932.2043955](http://dx.doi.org/10.1145/2043932.2043955).
  Formulas below are read from the author's version (Universidad Autónoma de Madrid repository,
  `rank_vargas_recsys_2011_ps.pdf`): eq. 8 and the normalisation after it (page 5), eq. 16 and the
  sentence after it (page 6).

---

## 1. Context

ILD (ADR 0002) counts every pair of results equally. A pair of near-duplicates at ranks 1 and 2
counts the same as one at ranks 9 and 10, and a pair of irrelevant results counts the same as a
pair of relevant ones. Search teams care about the top of the list and about relevant results, so
we wanted the metric the literature uses for this: **expected intra-list diversity (EILD)**, the
paper's generalisation of ILD "with the introduction of rank-sensitivity and relevance".

## 2. Decision

### 2.1 The metric, as the paper defines it

For a ranked list `R`, the paper's general scheme (eq. 8) is
`m(R|θ) = C · Σ_k disc(k) · p(rel|i_k) · nov(i_k|θ)`, with `C = 1/Σ_k disc(k)` (the expected
browsing depth). Taking the distance-based novelty of each result against the rest of the list
(θ = R) gives EILD (eq. 16):

```
EILD = Σ_k Σ_{l≠k}  C_k · disc(k) · disc(l|k) · p(rel|k) · p(rel|l) · d(k, l)

disc(l|k) = disc(max(1, l − k))                    -- the rank of l relative to k
C_k       = C / Σ_{l≠k} disc(l|k) · p(rel|l)       -- per-result normalisation
C         = 1 / Σ_k disc(k)
```

`DiversityCalculator.eild` implements this literally. With no discount and every `p(rel)` = 1 it is
exactly ILD (`2/(n(n−1)) Σ_{k<l} d`), as the paper notes; a test pins that limit.

### 2.2 The three choices the paper leaves open

| Choice | Our pick | Paper's alternative |
| --- | --- | --- |
| `d(k, l)` | cosine distance of the title embeddings (same as ILD) | any distance in [0, 1] |
| `disc(k)` | `1 / log2(k + 1)`, as in nDCG | any decreasing function: exponential, Zipfian, none |
| `p(rel|k)` | `rating / top of the scale`, clamped to [0, 1]; **unrated = 0**, as nDCG treats it | ERR-style `(2^g − 1) / 2^g_max` (eq. 13) |

The discount and the linear relevance are product choices (they read like nDCG and are easy to
explain). The paper's own experiments use the ERR-style relevance, so EILD values here are not
comparable with its published numbers. Changing either is one line in `DiversityCalculator` and
the relevance mapping in the runtime and `FetchService`.

### 2.3 Where it plugs in

It reuses ADR 0002's whole pipeline; only the weights are new.

- **A scorer:** `EILD@10` (`scoreByExpectedDiversity(10);`), communal, 0 to 3 scale, next to
  ILD@10. `Scorer#diversity_metric` is `:eild` for it, and `:ild` for `scoreByDiversity`.
- **Runtime:** the helper adds `relevance` (rating over the scale's top, 0 when unrated) to each
  result it sends, and `metric: "eild"` to the call. Relevance is worked out in the browser, where
  the scale and the ratings are, so the server needs neither.
- **Server:** `POST api/cases/:id/diversity/score` takes `metric` and each doc's `relevance`;
  `ResultDiversity#score(docs, metric:)` picks `ild` or `eild`. `FetchService` builds the same
  relevance from the case's ratings and the scorer's scale for background runs.
- **Ratings:** EILD reads ratings, so `Scorer#uses_ratings?` is true for it: the rating controls
  stay open, and the unrated nag applies, because unrated results are weighted 0.
- **Embeddings are not redone:** vectors are cached per case and embedder settings (ADR 0002), so
  changing a rating re-scores with a request that makes no embedding call.

### 2.4 Results without a vector

A result with no title has no vector. It takes no part in the sums but keeps its rank, so the
discounts of the others don't shift. (ILD drops it and compresses.) `C` is taken over the results
that have a vector. Fewer than two such results is no score, not 0.

### 2.5 Reading a score: how much is grades, how much is near-duplicates

*Derived from the formula above and checked numerically; **not built**. Nothing in the UI shows it.*

EILD is a weighted mean of distances, and the weights have a fixed total, so a score splits exactly
into a part that comes from grades and a part that comes from similarity:

```
EILD = M × D̄

M = C · Σ_k disc(k) · rel(k)           -- the grade part, 0 to 1
D̄ = EILD / M                           -- the similarity part: the rank- and relevance-weighted
                                          mean distance between results, 0 to about 1
```

Why: each result's inner weights `C_k · disc(l|k) · rel(l)` sum to `C`, so the weights of all pairs
sum to `C · Σ_k disc(k) · rel(k)`, which is M. The score is that mass times the weighted mean
distance.

- **M is the grades.** It is the rank-discounted share of relevance in the list: 1 when every
  result is fully relevant, lower for unrated and low-rated results, counting the top ranks most.
  It depends only on the ratings, not on the embeddings.
- **D̄ is the similarity.** It depends only on the embeddings (with the weights as the averaging).
  A low D̄ means the weighted results are alike.
- **A budget out of 1**, when distances are at most 1:

  | Share | Lost to |
  | --- | --- |
  | `1 − M` | grades: unrated or low-rated results, weighted by rank |
  | `M × (1 − D̄)` | very similar results |
  | `M × D̄` | nothing; this is the EILD score |

  So "EILD 0.31 = relevance 0.62 × diversity 0.50" says whether to rate more results or retrieve
  different ones.
- **Near-duplicates, pair by pair.** A pair's contribution is its weight
  `C_k · disc(k) · disc(l|k) · rel(k) · rel(l)` times its distance, and the contributions add up to
  EILD exactly. The pairs with a high weight and a low distance, two similar results at the top, are
  where the most is lost, and can be listed.

Checked numerically on 200 random lists (6-dimensional unit vectors, 2 to 10 results, relevance in
{0, ⅓, ⅔, 1}): the pair weights sum to M to about 1e-15.

Caveats:

- A result whose own relevance is 0, or whose neighbours are all irrelevant, contributes no term
  (the code skips it). M as written above still counts the second kind, so there the weights sum to
  M over the results that have a term, and `D̄ = EILD / M` reads slightly low. The product
  `M × D̄ = EILD` still holds by definition.
- Cosine distance can exceed 1 for opposite vectors. That is rare with text embeddings, but the
  three shares then don't add to exactly 1.
- The split is multiplicative between the two parts. Comparing against ILD, or against a
  relevance-1 version of the same list, gives a different attribution that depends on the order of
  comparison.

Showing it needs a side channel, because a scorer returns one number: `DiversityCalculator.eild`
would return `{score, relevance, diversity, pairs}`, the endpoint would pass it on, and the query
score would show it as a tooltip or in the expanded query.

## 3. Alternatives rejected

- **A rank-weighted ILD without relevance** (the unranked scheme with only a discount). It would
  reward pushing different but irrelevant results to the top, which is the failure EILD's
  relevance term exists to prevent.
- **α-nDCG and intent-aware metrics** (ERR-IA). They need labelled aspects or subtopics per
  query, which Quepid doesn't have; EILD needs only ratings and a distance.
- **The paper's ERR-style relevance.** It would match the paper's numbers but be harder to read
  next to an nDCG score on the same scale.

## 4. Consequences

- A case on EILD@10 needs ratings to mean anything: with none, every result has relevance 0 and the
  score is 0, not "no score". That is the metric's definition, and the unrated nag says so.
- Every rating change re-scores the query with a server call (cheap, no embedding).
- A different relevance mapping or discount would make stored scores and snapshots incomparable;
  nothing records which was used. Treat the formula above as part of the scorer's identity.

## 5. Open points

- The grades-versus-similarity breakdown in 2.5 is not built or shown anywhere.
- Not verified against another implementation or the paper's reference code; only the formulas
  were checked against the paper, and `DiversityCalculator`'s tests derive small cases by hand
  from them.
- `p(rel)` for graded scales whose lowest value isn't 0 (a custom scale starting at 1) is
  `rating / top`, which is not 0 for the lowest grade; a custom scale may want `(rating − bottom) /
  (top − bottom)`.
