import { CORE_EVENTS } from "utils/core_events"
import CoreModalControllerBase from "controllers/core_modal_controller_base"
import { getJson, putJson } from "api/json"
import { apiFetch } from "api/fetch"
import { serverMessage } from "utils/error_message"
import { getQuepidRootUrl } from "utils/quepid_root"

/**
 * Pick-scorer modal for the core case toolbar. Lists communal (+ custom, when
 * allowed) Rails-rendered scorer rows, saves via
 * `PUT api/cases/:id/scorers/:scorerId`, then dispatches
 * `pick-scorer:selected` so the live-query scorer can rescore
 * live queries until the live-query-state migration owns that path.
 *
 * When the case's current scorer is missing from the accessible lists, it
 * stays selected and the warning banner shows.
 *
 * A scorer that scores by result diversity (ILD, `uses_diversity`) needs an embedder to embed
 * the results' titles. It is chosen here, in a dropdown that appears for such a scorer, and
 * saved on the case with the scorer (`diversity_embedder_id`): the scorer is shared, the
 * embedder and its API key are not. Blank means the case's own embedder.
 */
export default class extends CoreModalControllerBase {
  static targets = [
    "item",
    "title",
    "alert",
    "warning",
    "warningName",
    "communalList",
    "customSection",
    "customList",
    "customEmpty",
    "createButton",
    "submitButton",
    "diversityPanel",
    "diversityEmbedder",
    "diversityNotice"
  ]

  static values = {
    scorersUrl: String,
    caseScorerUrlTemplate: String,
    embeddersUrlTemplate: String,
    communalScorersOnly: Boolean
  }

  openFor(btn) {
    this.openGeneration = (this.openGeneration || 0) + 1
    const caseId = this.triggerValue(btn, "id")
    const currentScorerId = this.triggerValue(btn, "currentScorerId")
    const currentScorerName = this.triggerValue(btn, "currentScorerName")

    this.currentCaseId = caseId || ""
    this.selectedScorer = null
    this._isSubmitting = false
    // Ignore non-numeric ids such as the legacy "default" scorer id.
    const parsedScorerId = currentScorerId ? Number(currentScorerId) : NaN
    this.initialScorerId = Number.isFinite(parsedScorerId) ? parsedScorerId : null
    this.initialScorerName = currentScorerName || ""
    this.userScorers = []
    this.communalScorers = []
    this.embedderState = null

    this.clearAlert()
    this._refreshCreateVisibility()
    return this._loadScorers()
  }

  selectScorer(event) {
    const scorerId = Number(event.params.scorerId)
    const pool = this.userScorers.concat(this.communalScorers)
    this.selectedScorer = pool.find((s) => Number(s.scorer_id) === scorerId) || null
    this._refreshListActive()
    this._refreshWarning()
    void this._refreshDiversityPanel()
    // Picking a real scorer must re-enable submit even when the modal opened
    // with an inaccessible placeholder selected (which leaves submit
    // disabled) or nothing selected at all — but must NOT clobber a submit
    // that's still in flight, so this only recomputes from _isSubmitting
    // rather than assuming "not submitting".
    this._refreshSubmitEnabled()
  }

  gotoScorers(event) {
    event?.preventDefault?.()
    this.hide()
    window.location.href = `${getQuepidRootUrl()}/scorers`
  }

  async submit(event) {
    event?.preventDefault?.()
    if (!this.selectedScorer || !this.currentCaseId || this.selectedScorer.inaccessible) return

    this.setSubmitting(true)
    this.clearAlert()

    const selectedScorer = this.selectedScorer
    const scorerId = selectedScorer.scorer_id
    const caseId = this.currentCaseId
    const generation = this.openGeneration

    try {
      const url = this.caseScorerUrlTemplateValue
        .replaceAll("__CASE_ID__", caseId)
        .replaceAll("__SCORER_ID__", String(scorerId))
      await putJson(url, this._scorerBody(selectedScorer))

      document.dispatchEvent(
        new CustomEvent(CORE_EVENTS.PICK_SCORER_SELECTED, {
          detail: { caseId: Number(caseId), scorer: selectedScorer }
        })
      )

      if (generation === this.openGeneration) this.hide()
    } catch (error) {
      console.error("pick-scorer-core: save failed", error)
      if (generation !== this.openGeneration) return
      const message = serverMessage(error, "Unable to save scorer.")
      this.showAlert(message, "danger")
      this.setSubmitting(false)
    }
  }

  async _loadScorers() {
    if (this.hasCommunalListTarget) this.communalListTarget.replaceChildren()
    if (this.hasCustomListTarget) this.customListTarget.replaceChildren()

    try {
      const response = await apiFetch(this.scorersUrlValue, { headers: { Accept: "text/html" } })
      if (!response.ok || response.redirected) throw new Error("Unable to load scorers")
      const html = new DOMParser().parseFromString(await response.text(), "text/html")
      const catalog = html.querySelector("[data-scorer-catalog]")
      if (!catalog) throw new Error("Missing scorer catalog")
      this._renderLists(catalog)

      // Keep the case's current scorer selected even when it is missing from
      // the accessible lists — that is what the inaccessible-scorer warning
      // is for.
      const pool = this.communalScorers.concat(this.userScorers)
      const initial = pool.find((s) => Number(s.scorer_id) === this.initialScorerId) || null
      if (initial) {
        this.selectedScorer = initial
      } else if (this.initialScorerId != null) {
        // Placeholder only — has no code/scale, so it must never be submitted
        // as-is (see #inaccessible guards in setSubmitting/submit). The user
        // has to explicitly pick an accessible scorer to proceed.
        this.selectedScorer = {
          scorer_id: this.initialScorerId,
          name: this.initialScorerName || `Scorer #${this.initialScorerId}`,
          inaccessible: true
        }
      } else {
        this.selectedScorer = null
      }
      this._refreshListActive()
      this._refreshWarning()
      this.setSubmitting(false)
      void this._refreshDiversityPanel()
    } catch (error) {
      console.error("pick-scorer-core: load scorers failed", error)
      this.showAlert("Unable to load scorers. Please try again.", "danger")
    }
  }

  _renderLists(catalog) {
    const communal = [...catalog.querySelector('[data-catalog-list="communal"]').children]
    const custom = [...catalog.querySelector('[data-catalog-list="custom"]').children]
    // Scorer data stays available to the immediate browser rescoring event.
    this.communalScorers = communal.map((row) => JSON.parse(row.dataset.scorerJson))
    custom.sort((a, b) => a.textContent.toLowerCase().localeCompare(b.textContent.toLowerCase()))
    this.userScorers = custom.map((row) => JSON.parse(row.dataset.scorerJson))
    if (this.hasCommunalListTarget) this.communalListTarget.replaceChildren(...communal)
    const showCustom = !this.communalScorersOnlyValue
    this.toggleVisible("customSection", showCustom)
    if (this.hasCustomListTarget) {
      this.toggleVisible("customList", showCustom)
      this.customListTarget.replaceChildren(...(showCustom ? custom : []))
    }
    this.toggleVisible("customEmpty", showCustom && custom.length === 0)
  }

  _refreshListActive() {
    const selectedId = this.selectedScorer ? Number(this.selectedScorer.scorer_id) : null
    const items = this.itemTargets
    items.forEach((li) => {
      const id = Number(li.dataset.pickScorerCoreScorerIdParam)
      li.classList.toggle("active", selectedId != null && id === selectedId)
    })
  }

  _refreshWarning() {
    if (!this.hasWarningTarget) return

    // Warning tracks the *case's* current scorer (initialScorerId), not the
    // in-modal selection.
    const accessible = this._initialScorerAccessible()
    this.toggleVisible("warning", !accessible)
    if (this.hasWarningNameTarget) {
      const name =
        this.initialScorerName ||
        (this.selectedScorer && Number(this.selectedScorer.scorer_id) === this.initialScorerId
          ? this.selectedScorer.name
          : "") ||
        (this.initialScorerId != null ? `Scorer #${this.initialScorerId}` : "")
      this.warningNameTarget.textContent = name
    }
  }

  _initialScorerAccessible() {
    if (this.initialScorerId == null) return true
    return this.userScorers
      .concat(this.communalScorers)
      .some((s) => Number(s.scorer_id) === this.initialScorerId)
  }

  // The request body: only a diversity scorer carries an embedder, and none (0) clears it.
  _scorerBody(scorer) {
    if (!scorer?.uses_diversity || !this.hasDiversityEmbedderTarget) return {}

    return { diversity_embedder_id: Number(this.diversityEmbedderTarget.value) || 0 }
  }

  // Shows the embedder dropdown for a diversity scorer, filled from the case's embedders.
  async _refreshDiversityPanel() {
    const wanted = Boolean(this.selectedScorer?.uses_diversity)
    this.toggleVisible("diversityPanel", wanted)
    if (!wanted || !this.hasDiversityEmbedderTarget || !this.currentCaseId)
      return this._refreshSubmitEnabled()

    if (!this.embedderState) {
      const generation = this.openGeneration
      try {
        const url = this.embeddersUrlTemplateValue.replaceAll("__CASE_ID__", this.currentCaseId)
        const state = await getJson(url)
        if (generation !== this.openGeneration) return
        this.embedderState = state
        this._renderDiversityEmbedders(state)
      } catch (error) {
        if (generation !== this.openGeneration) return
        this.showAlert(serverMessage(error, "Unable to load embedders."), "danger")
      }
    }
    this._refreshSubmitEnabled()
  }

  _renderDiversityEmbedders(state) {
    const caseEmbedder = state.embedder
    const options = [
      {
        value: "",
        label: caseEmbedder ? `The case's embedder (${caseEmbedder.name})` : "Choose an embedder…"
      },
      ...(state.embedders || []).map((embedder) => ({
        value: String(embedder.embedder_id),
        label: `${embedder.name} · ${embedder.model}`
      }))
    ]
    this.diversityEmbedderTarget.replaceChildren(
      ...options.map(({ value, label }) => {
        const option = document.createElement("option")
        option.value = value
        option.textContent = label
        return option
      })
    )
    this.diversityEmbedderTarget.value = state.diversity_embedder_id
      ? String(state.diversity_embedder_id)
      : ""
  }

  diversityEmbedderChanged() {
    this._refreshSubmitEnabled()
  }

  // A diversity scorer is no use without an embedder: the case's own, or one picked here.
  _diversityEmbedderMissing() {
    if (!this.selectedScorer?.uses_diversity || !this.hasDiversityEmbedderTarget) return false
    if (!this.embedderState) return true

    const picked = this.diversityEmbedderTarget.value
    const missing = !picked && !this.embedderState.embedder_id
    if (this.hasDiversityNoticeTarget) {
      this.diversityNoticeTarget.textContent = missing
        ? "This case has no embedder. Pick one here, or no embedders are shared with you yet."
        : ""
      this.toggleVisible("diversityNotice", missing)
    }
    return missing
  }

  _refreshCreateVisibility() {
    this.toggleVisible("createButton", !this.communalScorersOnlyValue)
  }

  setSubmitting(isSubmitting) {
    this._isSubmitting = isSubmitting
    this._refreshSubmitEnabled()
  }

  _refreshSubmitEnabled() {
    this.setButtonsDisabled(
      this._isSubmitting ||
        !this.selectedScorer ||
        this.selectedScorer.inaccessible ||
        this._diversityEmbedderMissing(),
      ["submitButton"]
    )
  }
}
