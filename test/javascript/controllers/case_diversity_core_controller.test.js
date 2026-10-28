import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { getJson, postJson, putJson } from "api/json"
import CaseDiversityCoreController from "controllers/case_diversity_core_controller"

vi.mock("api/json", () => ({
  getJson: vi.fn(),
  postJson: vi.fn(),
  putJson: vi.fn()
}))

const WITH_EMBEDDER = { embedder_id: 7, effective_diversity_depth: 10 }
const SNAPSHOTS = {
  snapshots: [
    { id: 3, name: "older" },
    { id: 8, name: "newer" }
  ]
}
const DONE = {
  running: false,
  diversity: 0.5,
  stale: false,
  title_field: "name",
  title_is_id: false,
  diversity_meta: { status: "done", depth: 10, queries_scored: 4, errors: [] }
}

function buildController() {
  const controller = Object.create(CaseDiversityCoreController.prototype)
  controller.element = document.createElement("section")
  controller.idValue = "5"
  controller.hasModalIdValue = true
  controller.modalIdValue = "caseEmbedderModal"
  controller.embeddersUrlTemplateValue = "api/cases/__CASE_ID__/embedders"
  controller.snapshotsUrlTemplateValue = "api/cases/__CASE_ID__/snapshots"
  controller.diversityUrlTemplateValue = "api/cases/__CASE_ID__/snapshots/__SNAPSHOT_ID__/diversity"
  controller.settingsUrlTemplateValue = "api/cases/__CASE_ID__/diversity_settings"
  controller.panelTarget = document.createElement("div")
  controller.noticeTarget = document.createElement("p")
  controller.depthInputTarget = document.createElement("input")
  controller.snapshotSelectTarget = document.createElement("select")
  controller.titleFieldTarget = document.createElement("code")
  controller.statusTarget = document.createElement("div")
  controller.computeButtonTarget = document.createElement("button")
  return controller
}

function routeGets(routes) {
  getJson.mockImplementation((url) => {
    const match = Object.entries(routes).find(([prefix]) => url.startsWith(prefix))
    if (!match) return Promise.reject(new Error(`unexpected GET ${url}`))
    return Promise.resolve(typeof match[1] === "function" ? match[1](url) : match[1])
  })
}

const openEvent = { target: { id: "caseEmbedderModal" } }

describe("CaseDiversityCoreController", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("asks for an embedder when the case has none", async () => {
    routeGets({ "api/cases/5/embedders": { embedder_id: null } })
    const controller = buildController()

    await controller.open(openEvent)

    expect(controller.panelTarget.hidden).toBe(true)
    expect(controller.noticeTarget.hidden).toBe(false)
    expect(controller.noticeTarget.textContent).toContain("Pick an embedder")
  })

  it("ignores other modals opening", async () => {
    const controller = buildController()

    await controller.open({ target: { id: "somethingElse" } })

    expect(getJson).not.toHaveBeenCalled()
  })

  it("lists snapshots newest first, selects it and shows its state", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": SNAPSHOTS,
      "api/cases/5/snapshots/8/diversity": DONE
    })
    const controller = buildController()

    await controller.open(openEvent)

    expect(controller.panelTarget.hidden).toBe(false)
    expect(controller.depthInputTarget.value).toBe("10")
    expect(
      [...controller.snapshotSelectTarget.options].map((option) => option.textContent)
    ).toEqual(["newer", "older"])
    expect(controller.snapshotSelectTarget.value).toBe("8")
    expect(controller.titleFieldTarget.textContent).toBe("name")
    expect(controller.statusTarget.textContent).toContain("Diversity@10: 0.500")
    expect(controller.computeButtonTarget.disabled).toBe(false)
  })

  it("says so when there is no snapshot to measure", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": { snapshots: [] }
    })
    const controller = buildController()

    await controller.open(openEvent)

    expect(controller.computeButtonTarget.disabled).toBe(true)
    expect(controller.statusTarget.textContent).toContain("Take a snapshot first")
  })

  it("tells the user to set a title field when the title is the id", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": SNAPSHOTS,
      "api/cases/5/snapshots/8/diversity": { ...DONE, title_is_id: true, diversity_meta: null }
    })
    const controller = buildController()

    await controller.open(openEvent)

    expect(controller.titleFieldTarget.textContent).toContain("set title:<field>")
  })

  it("compute posts, shows the run and polls until it finishes", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": SNAPSHOTS,
      "api/cases/5/snapshots/8/diversity": DONE
    })
    const controller = buildController()
    await controller.open(openEvent)
    postJson.mockResolvedValue({ ...DONE, running: true })

    await controller.compute()

    expect(postJson).toHaveBeenCalledWith("api/cases/5/snapshots/8/diversity")
    expect(controller.statusTarget.textContent).toBe("Computing diversity…")
    expect(controller.computeButtonTarget.disabled).toBe(true)

    await vi.advanceTimersByTimeAsync(3000)

    expect(controller.statusTarget.textContent).toContain("Diversity@10")
    expect(controller.computeButtonTarget.disabled).toBe(false)
    controller.disconnect()
  })

  it("shows why computing was refused", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": SNAPSHOTS,
      "api/cases/5/snapshots/8/diversity": DONE
    })
    const controller = buildController()
    await controller.open(openEvent)
    postJson.mockRejectedValue(new Error("You cannot use this case's embedder"))

    await controller.compute()

    expect(controller.statusTarget.textContent).toBe("You cannot use this case's embedder")
    expect(controller.statusTarget.className).toContain("text-danger")
    expect(controller.computeButtonTarget.disabled).toBe(false)
  })

  it("saves the depth and shows the state again", async () => {
    routeGets({
      "api/cases/5/embedders": WITH_EMBEDDER,
      "api/cases/5/snapshots?shallow=true": SNAPSHOTS,
      "api/cases/5/snapshots/8/diversity": DONE
    })
    const controller = buildController()
    await controller.open(openEvent)
    controller.depthInputTarget.value = "25"
    putJson.mockResolvedValue({ diversity_depth: 25, effective_diversity_depth: 25 })

    await controller.saveDepth()

    expect(putJson).toHaveBeenCalledWith("api/cases/5/diversity_settings", {
      diversity_depth: "25"
    })
    expect(controller.depthInputTarget.value).toBe("25")
  })

  it("shows a depth the server refused", async () => {
    const controller = buildController()
    controller.depthInputTarget.value = "1"
    putJson.mockRejectedValue(new Error("Diversity depth must be greater than or equal to 2"))

    await controller.saveDepth()

    expect(controller.statusTarget.textContent).toContain("greater than or equal to 2")
  })
})
