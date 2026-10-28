import { Controller } from "@hotwired/stimulus"
import { subscribeToStore } from "utils/store_subscription"
import { formatScore, scoreToColor, renderScoreState } from "utils/scoring"
import { getCoreStores } from "utils/core_store_access"
import { formatDiversity } from "utils/diversity_status"

export default class extends Controller {
  static targets = ["value"]
  static values = {
    queryId: String,
    index: Number
  }

  connect() {
    this.store = getCoreStores().documents
    this.onStoreChange = () => this.render()
    this.unsubscribeStore =
      this.store && subscribeToStore(this.store, { change: this.onStoreChange })
    this.render()
  }

  disconnect() {
    this.unsubscribeStore?.()
  }

  render() {
    const searcher = this.store?.query(this.queryIdValue)?.diffs?.searchers?.[this.indexValue]
    const score = searcher?.score?.score ?? "?"
    const maxScore = searcher?.score?.maxScore || 1
    this.element.style.backgroundColor = scoreToColor(score, maxScore)
    if (this.hasValueTarget) this.valueTarget.textContent = formatScore(score)
    renderScoreState(this.element, score, maxScore)
    this.renderDiversity(searcher?.diversity)
  }

  // The query's diversity in this snapshot, as a tooltip on the score: a number of its own would
  // crowd the badge, and it is the case-level value that gets the room.
  renderDiversity(diversity) {
    if (typeof diversity === "number") {
      this.element.title = `Diversity: ${formatDiversity(diversity)}`
    } else {
      this.element.removeAttribute("title")
    }
  }
}
