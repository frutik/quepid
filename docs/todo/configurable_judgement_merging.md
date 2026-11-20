# Configurable judgement merging: implementation plan

Plan for [ADR 0007](../adr/0007-configurable-judgement-merging.md). Target: upstream
o19s/quepid, in PR-sized batches. Each batch is additive and leaves every existing book on the
same ratings, except batch 3, which changes ratings on scales with gaps and says so.

## Scope

**Now: basic configurable merging (batches 1–3).** Each book picks a named built-in rule and,
optionally, precedence tiers by judge kind. This solves #1839.

**Later: weighted and scripted merging (batches 4–5).** The design is kept below so it can be
picked up unchanged. Batch 2 leaves room for both: weighting is a book flag on the rules batch 2
adds, and a script is one more rule behind the same input contract.

## 0. Before any code

- **Build end to end without waiting for the ADR to be accepted.** One commit (or PR-sized
  branch) per batch, so each can still go upstream separately. Open the ADR upstream in parallel
  and link it from #1839. If review changes the design (column or rule names), rework the
  affected batch before it goes upstream.
- **Done:** this branch includes o19s/quepid#1900 (ADR 0008, `judgements.confidence`), and
  ADR 0007 points at ADR 0008.
- **Fix the cross-link.** ADR 0008 links ADR 0007 as frutik/quepid#15. When ADR 0007 is opened
  upstream, change that link to the upstream PR in the same PR.
- **Code style.** Follow `docs/ai_coding_styleguide.md`. The batch notes below say where each
  rule applies. Comments that only explain the change to a reviewer start with `# PR:` and are
  removed before merge.

## Batch 1: extract the rule (refactor, no behaviour change)

Goal: one object that owns *select → combine → fit*, so later batches add rules instead of
editing `RatingsManager`.

- New `app/services/judgement_merger.rb` (name to settle in review):
  `JudgementMerger.new(book).rating_for(judgements)` returns a Float or `nil`.
  Move `calculate_rating_from_judgements` and the `round` / `support_implicit_judgements`
  branch into it as `quepid_classic`.
- `RatingsManager#sync_judgements_to_ratings` builds one merger per manager (memoised) and
  writes the rating only when the result is not `nil`. That is today's "no rateable judgements"
  path, generalised.
- Remove `RatingsManager#calculate_rating_from_judgements` in the same batch. Its only other
  caller is `test/services/ratings_manager_test.rb:112-195` (via `send`). Those cases move to the
  new merger test.
- Tests: `test/services/judgement_merger_test.rb` takes over the moved cases and adds what they
  don't cover: the non-monotonic cases from the calibration doc (`3,0 → 1.5`, `3,3,0 → 0`),
  rounding vs implicit books, and all-unrateable → `nil`. The sync tests left in
  `ratings_manager_test.rb` must pass unchanged.

## Batch 2: built-in rules and precedence tiers

- **Migration on `books`:**
  - `judgement_merge_rule` string, `null: false`, `default: 'quepid_classic'`
  - `judgement_merge_tiers` JSON (or text with a JSON serializer, matching `scale_with_labels`),
    default `nil` meaning "no tiers"
- **Book model:** make the rule a string-backed `enum` (style guide §3: a fixed set of states is
  an enum), with `validate: true` so a bad value is a validation error, not an exception. The
  form, the API and the docs table all read `Book.judgement_merge_rules` (style guide §7). Don't
  add a separate `RULES` constant. Validate tiers in the model as a subset of
  `%w[human ai anonymous]` with no duplicates.
- **Judge kind:** `human` / `ai` (`User#ai_judge?`) / `anonymous` (`user_id` nil). Load
  `query_doc_pair.judgements.rateable.includes(:user)` so classifying each judgement does not
  run an extra query.
- **Select:** the first tier with any judgement wins. Unlisted kinds form an implicit last tier.
- **Combine:** `mean`, `median` (mean of the two middle values for an even count), `min`, `max`,
  `majority` (tie → median).
- **Resync when the rule changes:** in an `after_update_commit` on Book, when the rule or tiers
  changed, enqueue `UpdateCaseJob.perform_later(book)`. That job already syncs only
  auto-populating cases and drives the "receives ratings" pulse.
- **Record the change.** The ADR wants score history to show when the rule changed. The smallest
  option is a case annotation on each affected case. This is an **open question for upstream**:
  ship it in this batch or defer it.
- **Surfaces that carry book attributes:**
  - Permitted params: three lists name book attributes today. They are `BooksController`
    (`book_params`, ~line 589), `Api::V1::BooksController` (~line 70) and
    `Books::ImportController` (line 15). Adding the new fields to all three is the duplication
    that style guide §4 says to share through a controller concern (`Books::ParameterFiltering`,
    shaped like `Connections::ParameterFiltering`). Do that, or add to all three and explain
    why in a `# PR:` comment.
  - The book export JSON and the import above, so a re-imported book keeps its rule.
  - `BookCombiner` needs no change. It combines source books *into an existing target book*,
    so the target's rule applies.
- **Docs:** the Quepid manual's averaging page describes `quepid_classic` as the default, not the
  only rule. Add a short table of the built-ins.
- **Tests:** one test per built-in. Tier selection: human present / absent, and an unlisted
  anonymous kind falling through. A Book validation test. A test that changing the rule enqueues
  `UpdateCaseJob`. An import round-trip.
- This batch answers #1839: `tiers: [human, ai]` + `mean`.

## Batch 3: snap to scale (small, behaviour change)

- Replace `calculated_rating.round` with "nearest value in `book.scale`, ties go up" for books
  without `support_implicit_judgements`. A book with an empty scale keeps `round`.
- `JudgeScale` is the value object for scales. Add `JudgeScale#nearest(value)` there instead of
  a new helper.
- Applies to every rule, `quepid_classic` included. On contiguous integer scales the result is
  identical, so tests should prove that and one gapped scale (e.g. `[0, 1, 3]`) should show the
  difference.
- Release note: ratings change only on gapped scales.
- Out of scope, but note it in the PR: `BookCombiner#merge_judgement` averages two of one judge's
  ratings and then calls `.round`, so on a gapped scale it can store an off-scale *judgement*.
  The same `JudgeScale#nearest` would fix it, in a separate PR.

## Later

Not built in this round. Kept as the design for the next one.

### Batch 4 (later): confidence weighting

- **Migration:** `books.weight_by_confidence` boolean, `null: false`, `default: false`.
- **Validation:** only allowed with `mean`, `median`, `majority`. The form hides or disables it
  for the other rules.
- **Weights:** `confidence || 1`, applied when the merge reads the value and never written back.
  - Weighted `mean`: Σcᵢrᵢ / Σcᵢ.
  - Weighted `median`: the exactly-half case averages that rating with the next one.
  - Weighted `majority`: a tie falls back to the weighted median.
  - If Σc is 0, use the unweighted form.
- **Resync on confidence change:** ADR 0008 §4 hands this to ADR 0007. It left `confidence` out
  of `Judgement#sync_case_ratings` on purpose, so that Jev re-runs don't resync cases that no
  rule reads. So the guard is **required**: resync on a confidence-only change only when
  `query_doc_pair.book.weight_by_confidence?`. The existing keys
  (`rating unrateable judge_later query_doc_pair_id`) keep resyncing for every book.
- **No storage, import or API work.** ADR 0008 already validates the range at the model, the
  importer and the API. The book export and import round-trip the value. Adapters always assign
  it, and `nil` means "reported none". Weighting only reads `judgement.confidence`.
- **Tests:**
  - The ADR §2.5 tables as fixtures: one human rating 3 and two AI judges rating 0 at 0.3 and
    0.4 give mean 2 and majority 3.
  - All weights 1 must equal the unweighted result.
  - A fallback test for zero total weight.
  - A confidence-only update enqueues a sync on a weighted book, and **does not** on an
    unweighted one.
  - An unrateable judgement that keeps its confidence is not weighted in.

### Batch 5 (later): custom JavaScript rules

- **Migration:** `books.judgement_merge_code` text. `judgement_merge_rule = 'custom'` selects it.
  Validate that the code is present when the rule is `custom`.
- **Runtime:** `lib/javascript_judgement_merger.rb`, modelled on `lib/javascript_scorer.rb`: one
  `MiniRacer::Context` per `RatingsManager` run, reused across pairs, with a per-call
  `timeout:` (the scorer runtime sets none today, so pick a value and note it).
  - Input: `{ judgements: [{ rating, judge_id, judge_kind, confidence (raw, may be null),
    updated_at, escalated_from }], scale }`.
  - Output: a number or `null`.
- **Failures:** a throw, timeout, non-number or off-scale value leaves the pair's previous rating,
  logs, and counts errors so `UpdateCaseJob` can report them. The sync never aborts.
  Fit-to-scale (batch 3) still runs after the script.
- **Form:** reuse the scorer code editor partial if it can be embedded. Ship one example script,
  the `tiers: [human, ai]` + `median` rule written out.
- **"Test this rule" button:** out of scope unless asked. A dry run over N pairs would be the
  natural follow-up.
- **Security:** the same trust model as scorers. Only users who can edit the book can set code.
  Confirm the permission check on the book update path covers the new param.
- **Tests:** a happy path, `null` keeps the old rating, throw / timeout / off-scale keep the old
  rating, and one context is reused across pairs (assert `MiniRacer::Context.new` is called once
  per run).

### Batch 6 (optional, unscheduled): case UI after a merge

ADR §1.1 explains why #1839 looked like lost data: `ratings_store.js` keeps the grade the person
picked, and the merged value only shows after a reload. Once tiers exist, the human grade *is* the
merged result for `[human, ai]` books, so the symptom goes away for that setup. For other rules,
broadcast the merged rating back to open case pages. This needs a separate UI decision and is not
in the ADR's decision section, so it is listed but not scheduled.

## Not planned here

Everything in ADR §5: reliability-weighted merging, distribution pooling, a generic confidence
floor, per-judge default confidence, juries of more than three, clearing ratings, and
disagreement flags.

## Order and dependencies

```
now:    1 ── 2 ── 3            (ADR review upstream runs alongside)
later:       2 ─┬─ 4  weighted
                └─ 5  scripted
```

Batch 3 depends only on batch 2. Batches 4 and 5 each need only batch 2 and are independent of
each other.
