import { buildControllerFixture } from "../support/controller_fixture"
import { scorerCatalogHtml } from "../support/modal_catalog_html"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { apiFetch } from "api/fetch"
import { getJson, putJson } from "api/json"
import PickScorerCoreController from "controllers/pick_scorer_core_controller"

vi.mock("api/fetch", () => ({ apiFetch: vi.fn() }))
vi.mock("api/json", () => ({ getJson: vi.fn(), putJson: vi.fn() }))
vi.mock("utils/bs_modal", () => ({
  getOrCreateBsModal: vi.fn(() => ({ hide: vi.fn(), show: vi.fn() })),
  hideBsModal: vi.fn()
}))

const AP = { scorer_id: 1, name: "AP@10", uses_diversity: false }
const ILD = { scorer_id: 2, name: "ILD@10", uses_diversity: true }

const STATE = {
  embedder_id: 7,
  embedder: { embedder_id: 7, name: "MiniLM" },
  embedders: [
    { embedder_id: 7, name: "MiniLM", model: "all-minilm" },
    { embedder_id: 9, name: "Voyage", model: "voyage-3.5" }
  ],
  diversity_embedder_id: null
}

function buildModalController() {
  const controller = buildControllerFixture(PickScorerCoreController, {
    overrides: { identifier: "pick-scorer-core" },
    targets: {
      title: document.createElement("h5"),
      alert: document.createElement("div"),
      warning: document.createElement("div"),
      warningName: document.createElement("span"),
      communalList: document.createElement("ul"),
      customSection: document.createElement("div"),
      customList: document.createElement("ul"),
      customEmpty: document.createElement("p"),
      createButton: document.createElement("button"),
      submitButton: document.createElement("button"),
      diversityPanel: document.createElement("div"),
      diversityEmbedder: document.createElement("select"),
      diversityNotice: document.createElement("p")
    },
    values: {
      scorersUrl: "/modal_catalogs/scorers",
      caseScorerUrlTemplate: "/api/cases/__CASE_ID__/scorers/__SCORER_ID__",
      embeddersUrlTemplate: "/api/cases/__CASE_ID__/embedders",
      communalScorersOnly: false
    }
  })
  controller.element.append(controller.communalListTarget, controller.customListTarget)
  Object.defineProperty(controller, "itemTargets", {
    get: () => [...controller.element.querySelectorAll('[data-pick-scorer-core-target~="item"]')]
  })
  return controller
}

async function open(controller, currentScorerId = "1") {
  apiFetch.mockResolvedValue({
    ok: true,
    text: async () => scorerCatalogHtml({ communal_scorers: [AP, ILD] })
  })
  await controller.openFor({
    dataset: { pickScorerCoreIdValue: "5", pickScorerCoreCurrentScorerIdValue: currentScorerId }
  })
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
const options = (controller) =>
  [...controller.diversityEmbedderTarget.options].map((option) => option.textContent)

describe("PickScorerCoreController, diversity scorer", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getJson.mockResolvedValue(STATE)
    putJson.mockResolvedValue({})
  })

  it("shows no embedder picker for an ordinary scorer, and asks for nothing", async () => {
    const controller = buildModalController()
    await open(controller)

    expect(controller.diversityPanelTarget.classList.contains("d-none")).toBe(true)
    expect(getJson).not.toHaveBeenCalled()

    await controller.submit()
    expect(putJson).toHaveBeenCalledWith("/api/cases/5/scorers/1", {})
  })

  it("shows the picker for ILD, with the case's embedder first and the shared ones after", async () => {
    const controller = buildModalController()
    await open(controller)

    controller.selectScorer({ params: { scorerId: 2 } })
    await settle()

    expect(controller.diversityPanelTarget.classList.contains("d-none")).toBe(false)
    expect(getJson).toHaveBeenCalledWith("/api/cases/5/embedders")
    expect(options(controller)).toEqual([
      "The case's embedder (MiniLM)",
      "MiniLM · all-minilm",
      "Voyage · voyage-3.5"
    ])
    expect(controller.diversityEmbedderTarget.value).toBe("")
  })

  it("preselects the embedder the case already uses for diversity", async () => {
    getJson.mockResolvedValue({ ...STATE, diversity_embedder_id: 9 })
    const controller = buildModalController()
    await open(controller, "2")
    await settle()

    expect(controller.diversityEmbedderTarget.value).toBe("9")
  })

  it("saves the chosen embedder with the scorer", async () => {
    const controller = buildModalController()
    await open(controller)
    controller.selectScorer({ params: { scorerId: 2 } })
    await settle()
    controller.diversityEmbedderTarget.value = "9"

    await controller.submit()

    expect(putJson).toHaveBeenCalledWith("/api/cases/5/scorers/2", { diversity_embedder_id: 9 })
  })

  it("sends 0 to fall back to the case's embedder", async () => {
    const controller = buildModalController()
    await open(controller)
    controller.selectScorer({ params: { scorerId: 2 } })
    await settle()

    await controller.submit()

    expect(putJson).toHaveBeenCalledWith("/api/cases/5/scorers/2", { diversity_embedder_id: 0 })
  })

  it("won't save ILD while there is no embedder to use", async () => {
    getJson.mockResolvedValue({ ...STATE, embedder_id: null, embedder: null })
    const controller = buildModalController()
    await open(controller)
    controller.selectScorer({ params: { scorerId: 2 } })
    await settle()

    expect(controller.submitButtonTarget.disabled).toBe(true)
    expect(controller.diversityNoticeTarget.classList.contains("d-none")).toBe(false)

    controller.diversityEmbedderTarget.value = "9"
    controller.diversityEmbedderChanged()

    expect(controller.submitButtonTarget.disabled).toBe(false)
    expect(controller.diversityNoticeTarget.classList.contains("d-none")).toBe(true)
  })

  it("hides the picker again when an ordinary scorer is picked", async () => {
    const controller = buildModalController()
    await open(controller)
    controller.selectScorer({ params: { scorerId: 2 } })
    await settle()

    controller.selectScorer({ params: { scorerId: 1 } })

    expect(controller.diversityPanelTarget.classList.contains("d-none")).toBe(true)
    expect(controller.submitButtonTarget.disabled).toBe(false)
  })
})
