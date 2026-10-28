import { Controller } from "@hotwired/stimulus"
import { getJson, postJson, putJson } from "api/json"
import { describeDiversity } from "utils/diversity_status"

const POLL_MS = 3000

/**
 * The "Diversity" section of the case embedder modal: how different the top results of each
 * query are from one another, measured on a snapshot with the case's embedder (see
 * ComputeSnapshotDiversityJob). Pick a snapshot, set how many top results to look at, and
 * compute; the result shows next to the snapshot's score when snapshots are compared.
 *
 * It sits inside shared/_case_embedder_core_modal.html.erb, which owns the URLs. It reloads
 * whenever that modal opens, and polls while a run is queued or under way -- the core page has
 * no ActionCable.
 */
export default class extends Controller {
  static targets = [
    "panel",
    "notice",
    "depthInput",
    "snapshotSelect",
    "titleField",
    "status",
    "computeButton"
  ]

  static values = {
    id: String,
    modalId: String,
    embeddersUrlTemplate: String,
    snapshotsUrlTemplate: String,
    diversityUrlTemplate: String,
    settingsUrlTemplate: String
  }

  disconnect() {
    clearTimeout(this.pollTimer)
  }

  // Bound to the modal's show event on the document: the section is inside the modal, so it
  // can't listen to it directly.
  async open(event) {
    if (event?.target?.id && this.hasModalIdValue && event.target.id !== this.modalIdValue) return

    clearTimeout(this.pollTimer)
    this.panelTarget.hidden = true
    this.noticeTarget.hidden = true

    try {
      const state = await getJson(this.url(this.embeddersUrlTemplateValue))
      if (!state.embedder_id) {
        this.showNotice("Pick an embedder to measure the diversity of results.")
        return
      }

      this.depthInputTarget.value = state.effective_diversity_depth
      this.panelTarget.hidden = false
      await this.loadSnapshots()
    } catch (error) {
      this.showNotice(error.message || "Unable to load diversity.")
    }
  }

  async loadSnapshots() {
    const payload = await getJson(`${this.url(this.snapshotsUrlTemplateValue)}?shallow=true`)
    const snapshots = (payload.snapshots || []).slice().sort((a, b) => b.id - a.id)

    this.snapshotSelectTarget.replaceChildren(
      ...snapshots.map((snapshot) => {
        const option = document.createElement("option")
        option.value = snapshot.id
        option.textContent = snapshot.name
        return option
      })
    )
    this.snapshotSelectTarget.disabled = snapshots.length === 0
    this.computeButtonTarget.disabled = snapshots.length === 0

    if (snapshots.length === 0) {
      this.titleFieldTarget.textContent = ""
      this.renderStatus({
        text: "Take a snapshot first; diversity is measured on one.",
        tone: "muted"
      })
      return
    }

    await this.refresh()
  }

  async snapshotChanged() {
    await this.refresh()
  }

  async refresh() {
    const snapshotId = this.snapshotSelectTarget.value
    if (!snapshotId) return

    try {
      this.apply(await getJson(this.diversityUrl(snapshotId)))
    } catch (error) {
      this.renderStatus({ text: error.message || "Unable to load diversity.", tone: "danger" })
    }
  }

  apply(state) {
    this.titleFieldTarget.textContent = state.title_is_id
      ? "none — set title:<field> in the try's field spec"
      : state.title_field
    this.renderStatus(describeDiversity(state))
    this.computeButtonTarget.disabled = Boolean(state.running)

    clearTimeout(this.pollTimer)
    if (state.running) this.pollTimer = setTimeout(() => this.refresh(), POLL_MS)
  }

  renderStatus({ text, tone }) {
    this.statusTarget.textContent = text
    this.statusTarget.className = `small text-${tone === "muted" ? "muted" : tone}`
  }

  async compute() {
    const snapshotId = this.snapshotSelectTarget.value
    if (!snapshotId) return

    this.computeButtonTarget.disabled = true
    try {
      this.apply(await postJson(this.diversityUrl(snapshotId)))
    } catch (error) {
      this.renderStatus({ text: error.message || "Unable to compute diversity.", tone: "danger" })
      this.computeButtonTarget.disabled = false
    }
  }

  async saveDepth() {
    const value = this.depthInputTarget.value.trim()

    try {
      const settings = await putJson(this.url(this.settingsUrlTemplateValue), {
        diversity_depth: value
      })
      this.depthInputTarget.value = settings.effective_diversity_depth
      await this.refresh()
    } catch (error) {
      this.renderStatus({ text: error.message || "Unable to save the depth.", tone: "danger" })
    }
  }

  showNotice(message) {
    this.noticeTarget.textContent = message
    this.noticeTarget.hidden = false
  }

  url(template) {
    return template.replaceAll("__CASE_ID__", this.idValue)
  }

  diversityUrl(snapshotId) {
    return this.url(this.diversityUrlTemplateValue).replaceAll("__SNAPSHOT_ID__", snapshotId)
  }
}
