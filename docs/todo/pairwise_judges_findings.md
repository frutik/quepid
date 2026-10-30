# Can a cheap pairwise judge order search results? First findings

*Status: early results from a first probe on dev data, 2026-10-30. Nothing here is a benchmark.
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

## What this does not tell us

- Those pairs were the easy ones, the two extremes of a query. A ranking is decided by the close calls,
  and we have not measured those.
- The human ratings on that book are anonymous and averaged. Calibration needs a named rater, so the full
  experiment cannot run on it as it stands.
- We have not compared pairwise against Jev's pointwise grades, which is the actual question.
- Nothing about BlitzRank has been tested. Its published savings (the ADR cites 25–40% fewer tokens, and
  about 7× fewer than pairwise methods) come from its authors' own models. With six to ten results a query
  and batched requests, exhaustive comparison may already be cheap enough that it is not needed.

## What happens next

1. Get a reference with a named rater, so a calibration sample can be drawn by query.
2. Fix the pass bar in writing before running anything: pairwise round-robin must beat pointwise Jev on
   both tau-b and nDCG@10 against humans, by more than the run-to-run noise.
3. Run the experiment, with close calls included, and report the flip rate alongside the metrics.
4. If it passes, put it in the Calibration tab. If it does not, stop; BlitzRank would only make a weak
   oracle cheaper.

The result, whichever way it goes, gets written into ADR 0005.
