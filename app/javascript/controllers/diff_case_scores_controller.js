import { Controller } from "@hotwired/stimulus"
import { subscribeToStore } from "utils/store_subscription"
import { formatScore, scoreToColor, renderScoreState } from "utils/scoring"
import { getCoreStores } from "utils/core_store_access"
import { diversityComparable, diversityTooltip, formatDiversity } from "utils/diversity_status"

/**
 * Renders the case-level snapshot comparison scores.
 *
 * The live-query runtime still calculates these scores while scoring is being
 * migrated, but the header no longer depends on the old qscore-case
 * component or its scope bindings.
 */
export default class extends Controller {
  connect() {
    this.store = getCoreStores().documents
    // Case diffs change only with case-wide events; a single query's change can't affect them,
    // and re-rendering on every query's change during a large case's load adds up.
    this.onStoreChange = (event) => {
      if (event.detail.queryId == null) this.render()
    }
    this.unsubscribeStore =
      this.store &&
      subscribeToStore(this.store, { change: this.onStoreChange, reset: this.onStoreChange })
    this.render()
  }

  disconnect() {
    this.unsubscribeStore?.()
  }

  render() {
    this.element
      .querySelectorAll("[data-diff-case-scores-generated]")
      .forEach((badge) => badge.remove())
    const searchers = this.store?.caseDiffs() || []
    const comparable = diversityComparable(searchers.map((searcher) => searcher.diversity?.meta))

    searchers.forEach((searcher) => {
      const badge = document.createElement("div")
      badge.className = "case-score diff-score"
      badge.dataset.diffCaseScoresGenerated = "true"

      const rating = document.createElement("div")
      rating.className = "header-rating"
      const score = searcher.score?.score ?? "?"
      rating.style.backgroundColor = scoreToColor(score, searcher.score?.maxScore || 1)

      const value = document.createElement("span")
      value.className = "scorable-score"
      value.textContent = formatScore(score)

      const label = document.createElement("span")
      label.className = "query-score-label low-profile"
      label.textContent = searcher.name || "Snapshot"

      rating.append(value, label)
      renderScoreState(rating, score, searcher.score?.maxScore || 1)
      badge.append(rating)
      const diversity = this.diversityLine(searcher.diversity, comparable)
      if (diversity) badge.append(diversity)
      this.element.append(badge)
    })
  }

  // The snapshot's result diversity under its score, when it has one. Flagged when the value
  // was made with other settings than the case has now (outdated), or than the other snapshots
  // being compared (not comparable).
  diversityLine(diversity, comparable) {
    if (typeof diversity?.value !== "number") return null

    const line = document.createElement("div")
    line.className = "diff-diversity small text-center text-muted"
    const flags = []
    if (diversity.stale) flags.push("outdated")
    if (!comparable) flags.push("not comparable")
    line.textContent =
      `diversity ${formatDiversity(diversity.value)}` +
      (flags.length > 0 ? ` (${flags.join(", ")})` : "")
    line.title = diversityTooltip(diversity.meta)
    if (flags.length > 0) line.classList.add("text-warning")
    return line
  }
}
