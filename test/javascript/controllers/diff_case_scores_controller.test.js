import { buildControllerFixture } from "../support/controller_fixture"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import DiffCaseScoresController from "controllers/diff_case_scores_controller"
import { QueryDocumentsStore } from "stores/query_documents_store"

let testStores

vi.mock("utils/core_store_access", () => ({ getCoreStores: () => testStores || {} }))

describe("DiffCaseScoresController", () => {
  let element
  let store

  beforeEach(() => {
    element = document.createElement("div")
    store = new QueryDocumentsStore()
    testStores = { documents: store }
  })

  afterEach(() => {
    testStores = undefined
  })

  it("renders case-level snapshot scores from the document store", () => {
    store.setCaseDiffs([
      { name: "Baseline", score: { score: 0.75, maxScore: 1 } },
      { name: "Tuned", score: { score: "--", maxScore: 1 } }
    ])

    const controller = buildControllerFixture(DiffCaseScoresController, {
      element
    })
    controller.connect()

    expect(element.querySelectorAll(".case-score")).toHaveLength(2)
    expect(element.textContent).toContain("0.75")
    expect(element.textContent).toContain("Baseline")
    expect(element.textContent).toContain("Tuned")
    expect(element.querySelectorAll(".scorable-score")[1].textContent).toBe("--")
  })

  it("keeps existing score elements as direct siblings", () => {
    const primary = document.createElement("div")
    primary.className = "case-score"
    element.append(primary)

    store.setCaseDiffs([{ name: "Baseline", score: { score: 0.75 } }])

    const controller = buildControllerFixture(DiffCaseScoresController, {
      element
    })
    controller.connect()

    expect(element.children[0]).toBe(primary)
    expect(element.children[1].classList.contains("case-score")).toBe(true)
    expect(element.children[1].dataset.diffCaseScoresGenerated).toBe("true")
  })

  it("removes the badges when comparisons are cleared", () => {
    const controller = buildControllerFixture(DiffCaseScoresController, {
      element
    })
    controller.connect()

    store.setCaseDiffs([{ name: "Baseline", score: { score: 0.75 } }])
    expect(element.querySelectorAll(".case-score")).toHaveLength(1)

    store.clearCaseDiffs()
    expect(element.querySelectorAll(".case-score")).toHaveLength(0)
  })

  it("removes the badges when the document store resets", () => {
    const controller = buildControllerFixture(DiffCaseScoresController, {
      element
    })
    controller.connect()

    store.setCaseDiffs([{ name: "Baseline", score: { score: 0.75 } }])
    expect(element.querySelectorAll(".case-score")).toHaveLength(1)

    store.reset()
    expect(element.querySelectorAll(".case-score")).toHaveLength(0)
  })

  it("ignores single-query changes, which cannot change case diffs, without snapshotting every query", () => {
    const controller = buildControllerFixture(DiffCaseScoresController, { element })
    controller.connect()
    store.setCaseDiffs([{ name: "Baseline", score: { score: 0.75 } }])
    const snapshot = vi.spyOn(store, "snapshot")
    const render = vi.spyOn(controller, "render")

    store.collection.upsert({ queryId: 3 })
    store.updateQueryState(3, { notes: true })

    expect(render).not.toHaveBeenCalled()
    store.setCaseDiffs([])
    expect(render).toHaveBeenCalledOnce()
    expect(snapshot).not.toHaveBeenCalled()
    expect(element.querySelectorAll(".case-score")).toHaveLength(0)
  })

  it("renders no badges on a page without a documents store", () => {
    testStores = {}
    const controller = buildControllerFixture(DiffCaseScoresController, { element })

    expect(() => controller.connect()).not.toThrow()
    expect(element.querySelectorAll(".case-score")).toHaveLength(0)
  })

  it("unsubscribes on disconnect", () => {
    const controller = buildControllerFixture(DiffCaseScoresController, {
      element
    })
    controller.connect()
    controller.disconnect()

    store.setCaseDiffs([{ name: "Baseline", score: { score: 0.75 } }])
    expect(element.querySelectorAll(".case-score")).toHaveLength(0)
  })

  describe("diversity", () => {
    const meta = (overrides = {}) => ({
      status: "done",
      depth: 10,
      fingerprint: "abc",
      title_field: "name",
      embedder_name: "Voyage",
      ...overrides
    })

    function render() {
      const controller = buildControllerFixture(DiffCaseScoresController, { element })
      controller.connect()
    }

    it("shows a snapshot's diversity under its score", () => {
      store.setCaseDiffs([
        {
          name: "Baseline",
          score: { score: 0.75 },
          diversity: { value: 0.4234, meta: meta(), stale: false }
        }
      ])

      render()

      const line = element.querySelector(".diff-diversity")
      expect(line.textContent).toBe("diversity 0.423")
      expect(line.title).toContain("Diversity@10")
      expect(line.classList.contains("text-warning")).toBe(false)
    })

    it("shows nothing for a snapshot without a value", () => {
      store.setCaseDiffs([
        { name: "Baseline", score: { score: 0.75 }, diversity: { value: null, meta: null } },
        { name: "Tuned", score: { score: 0.5 } }
      ])

      render()

      expect(element.querySelectorAll(".diff-diversity")).toHaveLength(0)
    })

    it("flags an outdated value", () => {
      store.setCaseDiffs([
        {
          name: "Baseline",
          score: { score: 0.75 },
          diversity: { value: 0.4, meta: meta(), stale: true }
        }
      ])

      render()

      const line = element.querySelector(".diff-diversity")
      expect(line.textContent).toBe("diversity 0.400 (outdated)")
      expect(line.classList.contains("text-warning")).toBe(true)
    })

    it("flags values made in different ways as not comparable", () => {
      store.setCaseDiffs([
        { name: "A", score: { score: 0.7 }, diversity: { value: 0.4, meta: meta() } },
        {
          name: "B",
          score: { score: 0.7 },
          diversity: { value: 0.5, meta: meta({ title_field: "label" }) }
        }
      ])

      render()

      const lines = [...element.querySelectorAll(".diff-diversity")].map((line) => line.textContent)
      expect(lines).toEqual([
        "diversity 0.400 (not comparable)",
        "diversity 0.500 (not comparable)"
      ])
    })

    it("removes the diversity with the badge when comparisons are cleared", () => {
      store.setCaseDiffs([
        { name: "A", score: { score: 0.7 }, diversity: { value: 0.4, meta: meta() } }
      ])
      const controller = buildControllerFixture(DiffCaseScoresController, { element })
      controller.connect()

      store.clearCaseDiffs()
      controller.render()

      expect(element.querySelectorAll(".diff-diversity")).toHaveLength(0)
    })
  })
})
