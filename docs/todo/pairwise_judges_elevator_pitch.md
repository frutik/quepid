# Pairwise and BlitzRank judges — elevator pitch

> Decision record: [ADR 0005](../adr/0005-pairwise-and-listwise-ranking-judges.md). This page is the
> thirty-second version.

## The pitch

Our Jev judge answers *"how relevant is this document, 0–3?"* Jev can also answer *"which of these two
is more relevant?"* — and that is a question models, like people, get right more often than an
absolute grade. Turn a cheap stream of those answers into a full ranking of a query's results, and we
may get a more reliable ordering than the grades we have today, at a price we can afford.

## Why now

- Jev is already a provider (ADR 0001): fast, cheap, typed answers with probabilities.
- Judge calibration (PR #1827) already gives us what any new judge needs: a frozen sample of
  human-rated queries, agreement metrics, and a place in the UI to run them. We don't build a second
  evaluation system; we teach the first one to score *orderings*.

## What we do

1. **Pairwise Jev judge.** Ask Jev "A or B?" for two documents of a query, in randomised order, with
   its probability. Cache every answer so nothing is asked twice.
2. **Rank with it.** Start with the simple, honest approach: compare all pairs, count wins.
3. **Measure it in calibration** on the same human-rated queries, side by side with today's pointwise
   Jev: pairwise accuracy, Kendall's τ-b, nDCG@10 (human grades, judge's order), top-10 overlap,
   cost, and stability when we flip the candidate order.
4. **Only if pairwise wins, bring in BlitzRank** to cut the number of comparisons, and prove it
   keeps the quality.

## What this is not

- **Not a new way to produce relevance grades.** A ranking says A beats B, not whether either is
  any good, so it can't feed nDCG on its own. It reorders; humans and the pointwise judge still grade.
  We never write a ranking into a book's ratings.
- **Not a BlitzRank bet.** BlitzRank's savings (25–40% fewer tokens in its paper) were measured on
  other models, with k-wise calls. Jev's binary answers may leave little to save at our list sizes.
  We find out after we know pairwise works, not before.

## How we'll know

Before we run anything we fix the bar: pairwise Jev must beat pointwise Jev against human
judgements on the same queries. If it doesn't, we stop and have spent a small adapter extension and a
cache table, not a BlitzRank integration.

## The upside beyond ranking

Once we hold a preference graph, we can flag where it contradicts the pointwise grades — equal grades
but a strong preference, or reversed order, or a cycle — and send just those pairs to a second judge or
a human. That could raise the quality of the ratings we already have, which is worth more than another
ranking.

## The ask

Land judge calibration. Then a short, gated experiment: one adapter operation, one cache table, one
ranker, one calibration arm. Decision point after the experiment, with numbers.

## Risks worth saying out loud

- Nothing here is measured on Jev yet; every claim is a hypothesis the experiment is built to test.
- Pairwise costs more calls than pointwise (45 vs. 10 for ten results) — cheap only if Jev stays cheap.
- LLM judges prefer whichever option comes first and sometimes contradict themselves (A > B > C > A);
  the design randomises order and measures stability rather than assuming either away.
