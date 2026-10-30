# G1 pass bar — fixed before the run

Written 2026-10-30, before any ranking or pointwise answer exists for this sample. It follows
[pairwise_ranking_judges.md](pairwise_ranking_judges.md) §4 and [ADR 0005](../adr/0005-pairwise-and-listwise-ranking-judges.md) D5.

## Setup (all fixed)

- **Book:** Haystack Icecat Rating Party (book 4). **Reference:** user 12, "Rating Party consensus": the
  rounded mean of the book's anonymous ratings per pair (0–3). It is a crowd average, not a named human, so
  no human-vs-human ceiling can be computed; the result is "agreement with the crowd".
- **Sample:** calibration sample 5, drawn by query: 30 queries, 254 pairs, each query's rated documents only
  (at least 5 each, at least 2 distinct grades). nDCG is therefore over the rated subset, not a live top 10.
- **Judge:** the `jev` AI judge (`jev-latest`, 1.14.0), its saved prompt, unchanged.
- **Arms on the same sample:** search order (floor); pointwise Jev with the book's 0–3 scale and its minimum
  confidence **cleared** (a floor of 0.8 would leave most answers unrateable and handicap this arm; labels
  Irrelevant / Weak match / Good match / Perfect match, because the book has none); pairwise round-robin.
- **One run each.** No prompt, label or option changes after seeing a result. A change is a new
  experiment, stated as one.

## Metrics

Per query, then macro-averaged: Kendall's tau-b and nDCG@10 against the reference grades; also pairwise
accuracy and top-10 overlap, reported but not decisive. Calls and tokens per query. Stability: tau-b between
the order from the candidates forwards and from the candidates reversed.

## Verdict

Let d(q) = metric(pairwise, q) − metric(pointwise, q) for each query, and take a paired bootstrap over the 30
queries (5,000 resamples, seed 1).

**Pass** only if, for **both** tau-b and nDCG@10:

1. the mean of d is at least **0.02**, and
2. the lower end of the 95% bootstrap interval of the mean of d is **above 0**, and
3. pairwise also beats the search order on that metric (macro mean).

**Inconclusive** (do not proceed, do not stop for good) if stability tau-b is below **0.7**, or fewer than 25
queries have a defined tau-b for both arms.

**Fail** otherwise. A fail means ADR 0005 is marked *Deprecated* with this result as the addendum, and P6
onward is not built.

## Not claimed

That a better ordering means better grades; that this crowd average is a human ceiling; that the result
carries over to long-text books, where position bias was large (ADR 0005 Appendix A).
