# ADR 0007 — Configurable judgement merging: a per-book rule for turning a pair's judgements into one rating

- **Status:** Proposed
- **Date:** 2026-11-14
- **Affects (when built):** `app/services/ratings_manager.rb`, `app/models/book.rb` (and its form),
  `app/models/judgement.rb` (the `after_commit` sync), `lib/` (a server-side runtime for custom
  rules, next to `lib/javascript_scorer.rb`)
- **Builds on:** [ADR 0001](./0001-llm-judge-provider-architecture.md) (AI judges are `User` rows
  writing ordinary judgements), `docs/todo/judge_agreement_and_calibration.md` §2.7 and §3.8–3.10,
  `docs/todo/escalating_judges.md`
- **Answers:** [o19s/quepid#1839](https://github.com/o19s/quepid/issues/1839) ("Human expert
  override should take absolute priority over AI judge ratings")

---

## 1. Context

### 1.1 What Quepid does today

A book collects judgements: at most one row per judge per query–doc pair (a unique index on
`user_id, query_doc_pair_id`; anonymous imported judgements have no user). Cases do not read
judgements. They read a single `Rating` per query and doc. Two flows connect the two:

- **Book → case.** When a judgement's rating, `unrateable` or `judge_later` changes,
  `Judgement#sync_case_ratings` hands the pair to `JudgementSync`. That enqueues
  `UpdateCaseRatingsJob` once per pair, or once per batch during imports and AI judging.
  `RatingsManager#sync_judgements_to_ratings` then merges the pair's judgements and writes the
  result into every case of the book with `auto_populate_case_judgements`. Syncing a whole case from
  its book (`sync_ratings_for_case`) uses the same method.
- **Case → book.** Rating a doc in a case (`api/v1/queries/ratings`, `api/v1/bulk_ratings`, the
  ratings importer) calls `JudgementSync.from_ratings`. `JudgementFromRatingJob` then writes that
  rating as **the current user's judgement** on the matching pair of the case's book. That judgement
  triggers the book → case flow, so the case's `Rating` is overwritten with the merged value. A
  person who picks a grade in a case can see it turn into an average a moment later. That is the
  behaviour #1839 reports.

`RatingsManager#calculate_rating_from_judgements` is the only place in the codebase that merges
judgements. It is hard-coded:

1. Keep the pair's `rateable` judgements, dropping unrateable and judge-later rows.
2. If there are one or two, take the mean.
3. If there are three or more, take the three highest. If they agree, use that value. Otherwise use
   the **lowest of the three**.
4. If the book does not have `support_implicit_judgements`, round the result.
5. If no rateable judgement remains, write nothing: the case keeps whatever `Rating` it had.

Two other mechanisms shape what reaches the rule:

- **Escalation.** When an AI judge's answer is unrateable, an on-call judge rates the pair, and the
  new judgement points at the old one (`escalated_from_judgement_id`). The unrateable row is dropped
  in step 1, so an escalated pair is usually decided by the escalation judge alone.
- **The three-judgement cap.** The judging queue (`SelectionStrategy`, `HAVING COUNT < 3`) stops
  offering a pair once it has three judgement rows. More arrive only through imports or ratings made
  in cases, so in practice the "three or more" branch is the "exactly three" branch.

This rule came in with #1597. The calibration research (§2.7) shows it is not monotonic: adding a
higher vote can lower the rating (`3, 0 → 1.5` but `3, 3, 0 → 0`), and it changes behaviour
between two judges (equal weight) and three (the strictest judge decides). It assumes judges
overrate. §2.1 of that document shows that a judge's bias direction has to be measured per judge
and cannot be assumed.

### 1.2 What users are asking for

- **#1839 (apavlychev):** one AI judge rates the bulk of a book and one human re-rates selected
  pairs. Today the two are averaged. The human's grade should win. Deleting the AI judgement is not
  an option, because the AI judge is re-run incrementally while its prompt is tuned.
- **frutik, on the same issue:** "human always wins" is too simple. What happens with two or three
  humans, and whose grade takes precedence? It should at least be a choice that can be switched
  off.
- **epugh, on the same issue:** the current rule was a simple first pass. Options: "ship a bit of
  JavaScript that lets you write your specific logic", as scorers do, or "a matrix of options".
- **apavlychev, again:** a script, "similar to how scorers work".

### 1.3 What research and practice say

These are summarised from [LLM as Judge](https://frutik.github.io/awesome-search/Concepts/LLM-as-Judge),
[LLM Jury](https://frutik.github.io/awesome-search/Concepts/LLM-Jury) and calibration doc §2.7.

- **Humans set the standard and the LLM scales it.** Etsy and Dropbox Dash anchor their LLM judges
  to human gold labels. Keeping humans in the loop for ambiguous cases and close comparisons is a
  standing recommendation. That supports precedence for humans *as a policy a team chooses*, not as
  a law.
- **LLM juries vote or average.** PoLL (Verga et al. 2024) uses majority voting for binary verdicts
  and average pooling for graded scores, because a small panel often has no clear majority. A
  diverse panel beat a single GPT-4 judge on human agreement at 7–8× lower cost.
- **TREC mostly avoids merging.** The topic author is the primary assessor. Voorhees' union (*any*
  judge says relevant) and intersection (*all* do) sets were robustness experiments. Intersection is
  the honest form of "be pessimistic": the minimum over **all** judges, applied the same way at
  every judge count.
- **Majority vote is the crowdsourcing baseline.** Models that learn each judge's reliability from
  the data (Dawid & Skene, GLAD, MACE) beat it. They need overlap between judges, which Quepid only
  starts collecting with the calibration sample (calibration doc D6).
- **Agreement is not accuracy.** A unanimous jury can still be wrong. No merging rule replaces
  measuring judges against a human reference.

No single rule fits every book. A book with one human expert and one AI judge, a book with three
crowd workers, and a book with a panel of three LLMs from different families each need a different
rule. What is wrong with today is not the specific rule. It is that the rule is **fixed, implicit,
and the same for every book**.

## 2. Decision

**Each book chooses how its judgements are merged into a rating.** The rule is a pipeline with one
input contract. Quepid ships named built-in rules, and a book can instead supply its own
JavaScript, the way scorers do. The current rule remains the default.

### 2.1 Where the rule lives

On the **book**. Judgements belong to a book, `RatingsManager` is constructed per book, and every
case that auto-populates from a book receives the same ratings. A per-case rule would let two
cases read the same judgements differently and silently disagree, so this ADR rejects it.

### 2.2 The pipeline

```
rateable judgements ──► 1. select ──► 2. combine ──► 3. fit to scale ──► Rating (or none)
```

1. **Select:** decide which judgements count. Optional **precedence tiers** apply: the first tier
   that has any judgement on the pair is used, and lower tiers are ignored *for that pair*. They are
   ignored, not deleted or locked. An AI judge keeps re-rating, its judgements stay visible and
   measurable for calibration, and they count again as soon as the higher tier is empty.
   - Tiers are expressed over judge **kind**, which Quepid already knows: `human`, `ai`
     (`User#ai_judge?`), and `anonymous` (`user_id` nil, from imported judgements). A book could
     later name specific judges in a tier. That is out of scope here.
   - A kind that no tier lists forms an implicit **last tier**, so `tiers: [human, ai]` still uses
     anonymous imported judgements on pairs that have neither. Unlisted kinds are never dropped.
   - With no tiers set, all judgements count, which is today's behaviour.
2. **Combine:** reduce the selected judgements to one number. The built-ins are:

   | Rule | Behaviour | Fits |
   |---|---|---|
   | `quepid_classic` (default) | today's rule: mean for 1–2, top-3-then-min for 3+ | existing books, unchanged |
   | `mean` | arithmetic mean | LLM panels on graded scales (PoLL); Quepid's 1–2 branch today |
   | `median` | median (the mean of the two middle values for an even count) | small panels with one outlier |
   | `min` | minimum over all | "be strict", stated openly (Voorhees' intersection) |
   | `max` | maximum over all | "any judge finds it relevant" (Voorhees' union) |
   | `majority` | most frequent grade. A tie falls back to `median` | binary scales, crowd-style panels |

   Combined with selection, these cover the cases in §1.2. For example, #1839 is
   `tiers: [human, ai]` + `mean`, and three humans over an AI judge is `tiers: [human, ai]` +
   `median`.
3. **Fit to scale:** this step stays **outside** the rule, as rounding is today, so a custom rule
   cannot write a value the book cannot hold. Books without `support_implicit_judgements` snap the
   result to the **nearest value on the book's scale** (`JudgeScale`), with ties going up, as Ruby's
   `round` does. On contiguous integer scales this is exactly today's `round`. It differs only on
   scales with gaps, where `round` can produce a value that is not on the scale.

### 2.3 Custom rules: one contract for everything

A book can replace *select + combine* with JavaScript. The built-ins are named implementations of
the same contract, so a custom rule can do anything a built-in does and nothing a built-in cannot
explain.

- **Input:** the pair's **rateable** judgements. Each has `rating`, `judge_id`,
  `judge_kind` (`human` / `ai` / `anonymous`), `updated_at` and `escalated_from` (whether this
  judgement escalated another). The input also carries the book's `scale`. It does not carry
  explanations, doc fields or other pairs. A rule merges one pair's votes. It is not a relevance
  model.
- **Output:** a number, or `null` for "no rating" (§2.4).
- **Runtime:** server-side MiniRacer, following `lib/javascript_scorer.rb` and
  `lib/v8_mapper_executor.rb`. It has the same trust model as scorers: whoever can edit the book can
  run code in a sandboxed V8 context with no I/O. It also has the same limits: one context per sync
  run, reused across pairs, with a timeout per call. A rule that throws or returns an off-scale
  value is reported, and the pair keeps its previous rating. The sync does not abort.

### 2.4 Behaviour that has to be pinned down

- **No rating.** A rule may return `null`. In that case, as today when a pair has no rateable
  judgement, the case's existing `Rating` for that doc is **left untouched**. Removing it would be
  more honest, but `Rating` does not record whether the sync or a person wrote it, and cases can be
  rated by hand. Deleting would destroy those ratings. The stale rating is a known limitation (§5).
- **Changing the rule re-scores.** Ratings are derived, so a new rule moves every auto-populated
  case fed by the book (calibration doc §3.10). Saving a different rule enqueues a resync of the
  book's cases, and the change is recorded so score history can show when the rule changed.
- **Default.** Existing books keep `quepid_classic`. Whether new books should default to `mean` or
  `median` (calibration doc §3.9) is a separate decision, because it changes what a newly created
  book means.
- **Exports.** Book judgement exports are unaffected, because they export raw judgements. Case
  rating exports (`api/v1/export/ratings_controller.rb`) read `Rating`, so they change with the
  rule, as they would after any resync.

## 3. Alternatives considered

- **Hard-code "human always wins" (#1839 as filed).** This solves one team's setup and is wrong for
  others: several humans, untrained humans next to a calibrated AI panel, or teams that want the
  human as one vote among several. It is one tier configuration under this ADR, not the whole
  design.
- **Lock a pair once a human rates it.** This mixes judging-workflow state with merging. It blocks
  AI re-judging, which #1839 needs, and it hides the AI judgement from calibration. Tiers give the
  same result without the lock.
- **Built-ins only, with no script.** These are simpler and enough for most books, but users on the
  issue asked explicitly for scorer-style scripts, and the script contract costs little once the
  built-ins sit behind it.
- **Script only, with no built-ins.** Everyone would write the same five lines, and nothing would
  tell a reader what a book's rule means without reading code. Named rules are self-documenting.
- **Per-judge weights now.** Hand-set weights are guesses. Weights that are worth having come from
  measured reliability (Dawid & Skene and successors), which needs the overlap data the calibration
  work only starts to collect. A custom script can already weight by `judge_id` if a team insists.
- **Confidence-weighted merging.** An AI judge's confidence is not persisted on judgements today,
  and stated confidence is known to be overconfident. Deferred (§5).
- **Rule per case.** Rejected in §2.1.

## 4. Consequences

- #1839 is solved without deleting or locking data, and the "only a Sith deals in absolutes"
  objection is answered: precedence is a book's choice, not Quepid's.
- The rule a book uses becomes visible and named, instead of being an undocumented property of
  `RatingsManager`. The Quepid manual page on averaging describes the default rule instead of the
  only one.
- There is another place where user JavaScript runs on the server, with the same exposure and
  limits as scorers.
- A merge has to run per pair on every judgement commit and every case sync. Built-ins are plain
  Ruby. A script costs one V8 call per pair, which is acceptable at book sizes where scorers already
  run server-side, and it must reuse one context per run.
- Snap-to-scale replaces `round`. It changes ratings only on scales with gaps, where `round` could
  produce an off-scale value. This should be called out in the release notes.
- Ratings stop being "the" truth about a pair. They are one reading of the judgements under a
  stated rule, which is what the calibration work already assumes.

## 5. Not in this ADR

- **Reliability-weighted merging** (Dawid & Skene, GLAD, MACE): a later built-in, once the
  calibration sample provides judge overlap (calibration doc D6–D7).
- **Confidence-aware merging:** needs AI-judge confidence persisted on judgements
  (`escalating_judges.md` §5.3).
- **Juries larger than three:** `SelectionStrategy` stops offering a pair at three judgements
  (`HAVING COUNT < 3`). Any rule here works with more judgements, but the judging queue has to
  change before a book can collect them.
- **Clearing ratings no rule produces:** needs a provenance column on `Rating` (written by the sync
  or by a person) before the sync may delete anything.
- **Disagreement as a signal:** flagging pairs whose judges disagree, for human adjudication, is
  measurement rather than merging. It belongs with the agreement statistics in the calibration
  plan.
