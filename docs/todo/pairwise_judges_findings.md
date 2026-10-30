# Can a cheap pairwise judge order search results? First findings

*Status: two experiments on two dev books, 2026-10-30: a clear win on one, an inconclusive result on the other. Promising, not a benchmark.
The decision record is [ADR 0005](../adr/0005-pairwise-and-listwise-ranking-judges.md) and the
build plan is [pairwise_ranking_judges.md](pairwise_ranking_judges.md).*

## The question

Quepid's AI judges rate one query and document at a time on the book's scale. That is the right tool
when you want grades, which scorers like nDCG need. It is not always the easiest question to answer
well. "Is this a 2 or a 3?" is harder for a model than "which of these two is better?", and the second
question is also cheap to ask.

A pairwise judge answers the second question. Ask it about enough pairs of one query's results and you
can build an order. Algorithms such as BlitzRank exist to build that order with fewer questions than
asking about every pair.

The trap is that an order is not a set of grades. Knowing A beats B beats C says nothing about whether
A and B are both perfect or both poor. So a pairwise judge here only reorders. It never writes a rating,
and it is judged by how well its order matches human grades, not by producing grades of its own.

The question we are testing: on the same human-rated queries, does a pairwise Jev ordering agree with
humans better than the ordering implied by Jev's own pointwise grades? Only if it does is it worth making
the ordering cheaper.

## What we built

Enough to ask the question, and no more:

- Jev can be asked "which of these two documents is more relevant to the query?" as a `choice` question.
- Every answer is cached per judge, prompt and pair, so a comparison is paid for once.
- Two ways to turn comparisons into an order: compare every pair and count wins (round-robin), or sort
  with the judge as the comparator (about n log n questions).
- A set of metrics against human grades: pairwise accuracy, Kendall's tau-b, nDCG@10, top-10 overlap
  and stability when the candidates are reversed.
- A rake task, `judges:rank_sample`, that ranks a calibration sample and prints those numbers next to the
  search's own order and the pointwise judge.

None of it touches judgements or ratings.

## What the live API does

We checked the assumptions against the real Jev API before trusting any of it.

**The format works.** A two-option `choice` question returns a probability for each option, a
confidence, and token usage (about 1,200 input tokens for two long documents).

**Ties can be asked for.** Adding a third option, `TIE`, gets its own probability. We have not yet checked
that Jev uses it sensibly.

**Questions batch.** Several questions in one request each get an answer, and the shared state (the query
and the documents) is sent once. The saving is in requests, not tokens.

**Position bias depends on the documents.** Models tend to favour whichever document they see first, so
we ask each pair in a swapped order half the time. How much that matters turned out to vary a lot:

| Data | Pairs | First-shown document won | Answer flipped when the order flipped |
| --- | --- | --- | --- |
| Long legal texts, six documents a query | 30 | 47 of 60 answers (78%) | 17–19 of 30 |
| Icecat product records (Haystack rating party) | 30 | 33–34 of 60 (about 55%) | 3–4 of 30 |

On the legal texts, Jev was confident (mean winner probability 0.72) while mostly answering about
position. On short product records it barely cared. Changing the labels from `A`/`B` to `1`/`2` and
swapping the pointwise prompt for a comparison-specific one made no measurable difference.

**On product records it mostly agrees with people.** For 30 queries we compared each query's best-rated
and worst-rated document, at least 1.5 grades apart on average. One answer matched the humans 82–83% of
the time. Asking both orders and requiring them to agree and match gave 23 of 30.

## The experiment: pairwise against pointwise

We fixed the pass bar in writing before running anything ([pairwise_g1_bar.md](pairwise_g1_bar.md)), then
ran the comparison once.

**Setup.** The Haystack Icecat Rating Party book: 30 queries, 254 query and document pairs, Icecat product
records. The reference is the average of the anonymous human ratings per pair, rounded to 0–3. Three ways
of ordering each query's documents were scored against it: the order the search returned, Jev's pointwise
grades (rate each document, sort by grade), and Jev pairwise (compare every pair of a query's documents,
sort by wins).

### The numbers

| Ordering | Kendall's tau-b | nDCG@10 | Pairwise accuracy |
| --- | --- | --- | --- |
| Search order | 0.019 | 0.799 | 0.505 |
| Pointwise Jev | 0.340 | 0.879 | 0.705 |
| Pairwise Jev (round-robin) | **0.466** | **0.922** | **0.804** |

Pairwise minus pointwise, per query, with a paired bootstrap over the 30 queries (5,000 resamples):

| Metric | Mean difference | 95% interval | Queries better / equal / worse |
| --- | --- | --- | --- |
| tau-b | +0.127 | 0.028 to 0.225 | 20 / 4 / 6 |
| nDCG@10 | +0.043 | 0.018 to 0.075 | 20 / 3 / 7 |

Stability, asking again with the candidates reversed: tau-b 0.893. Cost: 991 comparisons (33 a query),
667,564 tokens, 82 three-way contradictions (A beats B beats C beats A) across all queries, no ties.

### What that means in plain terms

- **The search's own order is about as good as random here.** Its tau-b of 0.02 says the order the search
  returned has almost no relationship with what people thought of the documents. That is why there is room
  to improve it.
- **Both Jev methods help, and pairwise helps more.** Asking Jev to pick the better of two documents put
  the documents in an order that agreed with the crowd noticeably more often than asking it to grade each
  one: 80% of the document pairs people rated differently were put the right way round, against 70% for
  grading and 50% for the search (a coin flip).
- **Where it matters most, the gain is real but moderate.** nDCG@10 is the number most people read. It went
  from 0.88 to 0.92, which is about four points. On a single query, pairwise did better than pointwise 20
  times, tied 3, and did worse 7.
- **It is unlikely to be luck, but only just.** The 95% intervals are above zero for both measures
  (0.03 to 0.23 for tau-b, 0.02 to 0.08 for nDCG). The lower ends sit close to the margin we set (0.02), so
  this is a pass, not a wide one.
- **It is steady.** Reversing the candidate list changed the order very little (0.89), so the result does
  not come from the order documents happened to arrive in.
- **It is not free.** About 33 comparisons per query, and around 670 tokens each, against one call per
  document for grading. At this list size that is a few hundred thousand tokens for the whole experiment.
  The 82 contradictions are small next to the number of comparisons, and round-robin copes with them by
  counting wins.

By the bar we wrote down first, **pairwise passed**: it beat pointwise by at least 0.02 on both measures,
the intervals excluded zero, it beat the search order, and it was stable.

## A second book: WANDS

The plan asks for two books, so we built one from WANDS, a public set of furniture and home products with
human labels (0 irrelevant, 1 partial match, 2 exact match). Same bar, written down first
([pairwise_g1_bar_wands.md](pairwise_g1_bar_wands.md)): 70 queries, the top 10 of a text search each with all
ten labelled, 30 queries sampled, 300 pairs.

| Ordering | Kendall's tau-b | nDCG@10 | Pairwise accuracy |
| --- | --- | --- | --- |
| Search order | 0.272 | 0.957 | 0.711 |
| Pointwise Jev | 0.354 | 0.972 | 0.785 |
| Pairwise Jev (round-robin) | 0.421 | 0.979 | 0.847 |

Pairwise minus pointwise: tau-b +0.067 (95% interval -0.042 to 0.164, defined for only 23 of 30 queries),
nDCG@10 +0.007 (-0.003 to 0.016). Stability 0.935. Cost: 1,350 comparisons, about 1.03 million tokens.

**In plain terms:** pairwise is ahead on every measure again, but this time the gaps are small enough that
they could be noise, and by our own bar the result is **inconclusive**. Two reasons the book cannot say much:

- **Nothing left to improve.** The search's own top 10 already scores 0.957 out of 1.0, because most of what
  a text search returns for these queries is labelled partial or exact. When the baseline is that high, no
  method can show a gain.
- **Seven queries have no spread.** In seven queries every document has the same label, so there is no order
  to agree or disagree with, and tau-b is undefined. That left 23 queries, under the 25 the bar needs.

The one measure with a visible gap is how often two documents with different labels are put the right way
round: 85% for pairwise against 79% for pointwise and 71% for the search. That is encouraging, but it was not
the measure the bar was built on, so it does not change the verdict.

**Overall, G1 is not passed:** one book passed, one was inconclusive, and the plan asks for both. The next test
should use a book where the search is not already close to perfect.

## What this does not tell us

- It is one book of short product records, 30 queries. Position bias was large on long legal texts, and
  nothing here says pairwise holds up there.
- The reference is a crowd average of anonymous ratings, not a named person, so we cannot say how close to
  a human ceiling either method is.
- Each query's list is only its rated documents, about eight, so nDCG@10 is over those and not over a live
  top 10. Top-10 overlap is 1.0 for every method for the same reason and tells us nothing.
- Pointwise was run with scale labels we wrote ourselves and no confidence floor. Different labels could
  move it. Pairwise used the same judging prompt.
- The test pairs were the rated documents of each query, including close calls, but we have not looked
  separately at how each method does on the closest ones.
- Nothing about BlitzRank has been tested. Its published savings (the ADR cites 25–40% fewer tokens, and
  about 7× fewer than pairwise methods) come from its authors' own models. At about 33 comparisons a query
  the exhaustive method may already be cheap enough that it is not needed.

## What happens next

1. Find or build a harder test: a book where the candidates are not the search's own top results, or the lists
   are deeper, so there is room for an ordering to improve. Keep the bar written down first.
2. Only if both books then pass, put ranking calibration in the Calibration tab so people can run it without
   a console.
3. Only then ask whether a cheaper method (comparison sort, then BlitzRank) is worth building. At 33 to 45
   comparisons a query and 700 to 800 tokens per comparison, the exhaustive method is affordable at these
   list sizes.

The full numbers and caveats are in ADR 0005, Appendices B and C.
