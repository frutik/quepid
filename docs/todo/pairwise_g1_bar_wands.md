# G1 pass bar, second book (WANDS) — fixed before the run

Written 2026-10-30, before any answer exists for this sample. Same rule as
[pairwise_g1_bar.md](pairwise_g1_bar.md); only the setup differs.

## Setup (all fixed)

- **Book:** "WANDS (ranking judge test)" (book 11): 70 queries from the WANDS case, each with the top 10 of a
  text search over the `wands` index (title weighted over description) and only queries whose ten results all
  carry a WANDS label. Documents carry `title`, `description`, `category`.
- **Reference:** user 13, "WANDS labels", the dataset's own labels: 0 Irrelevant, 1 Partial match, 2 Exact
  match. A named rater with one label per pair. Whole top-10 lists, so nDCG@10 is over a real top 10.
- **Sample:** calibration sample 6, drawn with the standard query sampling: 30 queries, 300 pairs.
- **Judge:** the `jev` AI judge, saved prompt unchanged. **Arms:** search order, pointwise Jev (the book's
  own scale and labels; minimum confidence cleared), pairwise round-robin. One run each.

## Metrics and verdict

Unchanged: per-query Kendall's tau-b and nDCG@10 against the reference, paired bootstrap over the 30 queries
(5,000 resamples, seed 1) of pairwise minus pointwise.

**Pass** only if for **both** tau-b and nDCG@10: mean difference at least **0.02**, the lower end of the 95%
interval above **0**, and pairwise beats the search order. **Inconclusive** if stability tau-b is below
**0.7** or fewer than 25 queries have a defined tau-b for both arms. **Fail** otherwise.

**G1 overall** (the plan asks for two books) passes only if this book and the Icecat book both pass.
If they disagree, G1 is not passed: the disagreement is written up and nothing past P5 is built until it is
understood.

No prompt, label or option changes after seeing a result.
