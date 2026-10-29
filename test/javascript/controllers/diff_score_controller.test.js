import { buildControllerFixture } from "../support/controller_fixture"
import { describe, expect, it } from "vitest"
import DiffScoreController from "controllers/diff_score_controller"

describe("DiffScoreController", () => {
  it("renders a diff score from the document store", () => {
    const element = document.createElement("div")
    element.innerHTML = '<span data-diff-score-target="value"></span>'
    const controller = buildControllerFixture(DiffScoreController, {
      element,
      targets: {
        value: element.querySelector("span")
      },
      values: {
        queryId: "1",
        index: 0
      },
      overrides: {
        store: {
          query: () => ({ diffs: { searchers: [{ score: { score: 0.5 } }] } })
        }
      }
    })

    controller.render()

    expect(controller.valueTarget.textContent).toBe("0.50")
    expect(controller.element.style.backgroundColor).toContain("hsl")
  })

  it("renders an unscored state when the diff is not ready", () => {
    const element = document.createElement("div")
    element.innerHTML = '<span data-diff-score-target="value"></span>'
    const controller = buildControllerFixture(DiffScoreController, {
      element,
      targets: {
        value: element.querySelector("span")
      },
      values: {
        queryId: "1",
        index: 0
      },
      overrides: {
        store: { query: () => ({ diffs: { searchers: [] } }) }
      }
    })

    controller.render()

    expect(controller.valueTarget.textContent).toBe("?")
  })

  it("shows the query's diversity as a tooltip, and clears it when there is none", () => {
    const element = document.createElement("div")
    element.innerHTML = '<span data-diff-score-target="value"></span>'
    let searcher = { score: { score: 0.5 }, diversity: 0.4123 }
    const controller = buildControllerFixture(DiffScoreController, {
      element,
      targets: { value: element.querySelector("span") },
      values: { queryId: "1", index: 0 },
      overrides: { store: { query: () => ({ diffs: { searchers: [searcher] } }) } }
    })

    controller.render()

    expect(element.title).toBe("Diversity: 0.412")

    searcher = { score: { score: 0.5 }, diversity: null }
    controller.render()

    expect(element.hasAttribute("title")).toBe(false)
  })
})
