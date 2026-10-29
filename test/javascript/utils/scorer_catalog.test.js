import { beforeEach, describe, expect, it, vi } from "vitest"
import { getJson } from "api/json"
import { createScorerCatalog, NO_RATINGS_CLASS } from "utils/scorer_catalog"

vi.mock("api/json", () => ({ getJson: vi.fn() }))

describe("scorer catalog", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    document.body.classList.remove(NO_RATINGS_CLASS)
  })

  it("starts with a default built from the shared runtime", () => {
    const catalog = createScorerCatalog()

    expect(catalog.getDefault().scale).toEqual(["0", "1"])
    expect(catalog.getDefault().score).toEqual(expect.any(Function))
  })

  it("bootstraps the case default from the API", async () => {
    getJson.mockResolvedValue({ default: { scorer_id: 7, name: "P@10", scale: [0, 1, 2, 3] } })
    const catalog = createScorerCatalog()

    await catalog.bootstrap(42)

    expect(getJson).toHaveBeenCalledWith("api/cases/42/scorers")
    expect(catalog.getDefault()).toEqual(
      expect.objectContaining({ scorerId: 7, name: "P@10", scale: [0, 1, 2, 3] })
    )
  })

  it("resets to a fresh default when the case has no configured scorer", async () => {
    getJson.mockResolvedValue({})
    const catalog = createScorerCatalog()
    await catalog.select({ scorer_id: 3 })

    await catalog.bootstrap(42)

    expect(catalog.getDefault().scorerId).toBeUndefined()
  })

  it("selects a scorer from API data as the new default", async () => {
    const catalog = createScorerCatalog()

    const selected = await catalog.select({ scorer_id: 9, name: "DCG@10" })

    expect(selected).toBe(catalog.getDefault())
    expect(selected).toEqual(expect.objectContaining({ scorerId: 9, displayName: "DCG@10" }))
  })

  it("builds every scorer with the shared scorer options", async () => {
    const schedule = vi.fn((callback) => callback())
    const catalog = createScorerCatalog({ scorerOptions: { schedule } })
    await catalog.select({ code: "setScore(5)" })

    await expect(catalog.getDefault().score({ ratedDocs: [] }, 1, [], [])).resolves.toBe(5)
    expect(schedule).toHaveBeenCalledOnce()
  })

  describe("rating controls", () => {
    const hidden = () => document.body.classList.contains(NO_RATINGS_CLASS)

    it("hides them while the scorer is one that never reads ratings", async () => {
      getJson.mockResolvedValue({ default: { scorer_id: 8, name: "ILD@10", uses_ratings: false } })
      const catalog = createScorerCatalog()

      await catalog.bootstrap(42)

      expect(hidden()).toBe(true)
    })

    it("shows them again when an ordinary scorer is selected", async () => {
      const catalog = createScorerCatalog()
      await catalog.select({ scorer_id: 8, name: "ILD@10", uses_ratings: false })
      expect(hidden()).toBe(true)

      await catalog.select({ scorer_id: 1, name: "AP@10", uses_ratings: true })

      expect(hidden()).toBe(false)
    })

    it("keeps them for a scorer that doesn't say", async () => {
      const catalog = createScorerCatalog()

      await catalog.select({ scorer_id: 3, name: "Custom" })

      expect(hidden()).toBe(false)
    })

    it("shows them when the case has no scorer configured", async () => {
      const catalog = createScorerCatalog()
      await catalog.select({ scorer_id: 8, uses_ratings: false })
      getJson.mockResolvedValue({})

      await catalog.bootstrap(42)

      expect(hidden()).toBe(false)
    })
  })
})
