import { describe, expect, it, vi } from "vitest"
import { createSnapshotModel } from "utils/snapshot_model"

describe("snapshot model", () => {
  it("normalizes query metadata and exposes unique document ids", () => {
    const snapshot = createSnapshotModel({
      params: {
        id: 4,
        time: "2026-09-26T12:00:00Z",
        name: "baseline",
        queries: {
          7: { query_id: 7, query_text: "blue shoes" }
        },
        docs: {
          7: [{ id: "a" }, { id: "a" }, { id: "b" }]
        }
      },
      getDoc: () => null,
      explainDoc: (doc) => doc,
      formatDate: () => "9/26/26"
    })

    expect(snapshot.queries[7].queryId).toBe(7)
    expect(snapshot.queries[7].queryText).toBe("blue shoes")
    expect(snapshot.docIdsPerQuery[7]).toEqual(["a", "a", "b"])
    expect(snapshot.allDocIds()).toEqual(["a", "b"])
    expect(snapshot.name()).toBe("(9/26/26) baseline")
  })

  it("hydrates cached documents without mutating the cache", () => {
    class CachedDoc {
      constructor() {
        this.id = "doc-1"
        this.title = "Title"
        this.nested = { value: 1 }
      }

      describe() {
        return "cached behavior"
      }
    }

    const cachedDoc = new CachedDoc()
    const explainDoc = vi.fn((doc, explain) => ({ ...doc, explain }))
    const snapshot = createSnapshotModel({
      params: {
        id: 4,
        name: "baseline",
        time: "2026-09-26T12:00:00Z",
        docs: {
          7: [{ id: "doc-1", explain: '{"value":2}', rated_only: true }]
        }
      },
      getDoc: () => cachedDoc,
      explainDoc,
      formatDate: () => "9/26/26"
    })

    expect(snapshot.getSearchResults(7)).toEqual([
      expect.objectContaining({
        id: "doc-1",
        explain: { value: 2 },
        rated_only: true
      })
    ])
    expect(cachedDoc).toEqual({ id: "doc-1", title: "Title", nested: { value: 1 } })
    expect(explainDoc).toHaveBeenCalledOnce()
    expect(explainDoc.mock.calls[0][0].describe()).toBe("cached behavior")
  })

  it("accepts explain data that is already parsed", () => {
    const snapshot = createSnapshotModel({
      params: {
        id: 4,
        name: "baseline",
        time: "2026-09-26T12:00:00Z",
        docs: { 7: [{ id: "doc-1", explain: { value: 2 } }] }
      },
      getDoc: () => ({ id: "doc-1" }),
      explainDoc: (doc, explain) => ({ ...doc, explain })
    })

    expect(snapshot.getSearchResults(7)[0].explain).toEqual({ value: 2 })
  })

  it("returns recorded query errors and skips missing documents", () => {
    const log = vi.fn()
    const snapshot = createSnapshotModel({
      params: {
        id: 4,
        name: "baseline",
        time: "2026-09-26T12:00:00Z",
        scores: [{ query_id: 7, error: "mapper failed" }],
        docs: { 7: [{ id: "missing", explain: "{}" }] }
      },
      getDoc: () => null,
      explainDoc: (doc) => doc,
      log
    })

    expect(snapshot.getQueryError(7)).toBe("mapper failed")
    expect(snapshot.getSearchResults(7)).toEqual([])
    expect(log).toHaveBeenCalledWith("Document with id missing is null")
  })

  it("exposes the snapshot's and each query's diversity", () => {
    const snapshot = createSnapshotModel({
      params: {
        id: 4,
        name: "baseline",
        diversity: 0.42,
        diversity_meta: { status: "done", depth: 10 },
        diversity_stale: true,
        scores: [
          { query_id: 7, diversity: 0.5 },
          { query_id: 8, diversity: null }
        ]
      },
      getDoc: () => null,
      explainDoc: (doc) => doc
    })

    expect(snapshot.diversity).toBe(0.42)
    expect(snapshot.diversityMeta).toEqual({ status: "done", depth: 10 })
    expect(snapshot.diversityStale).toBe(true)
    expect(snapshot.getDiversity(7)).toBe(0.5)
    expect(snapshot.getDiversity("7")).toBe(0.5)
    expect(snapshot.getDiversity(8)).toBeNull()
    expect(snapshot.getDiversity(99)).toBeNull()
  })

  it("has no diversity for a snapshot that never computed it", () => {
    const snapshot = createSnapshotModel({
      params: { id: 4, name: "baseline" },
      getDoc: () => null,
      explainDoc: (doc) => doc
    })

    expect(snapshot.diversity).toBeNull()
    expect(snapshot.diversityMeta).toBeNull()
    expect(snapshot.diversityStale).toBe(false)
    expect(snapshot.getDiversity(7)).toBeNull()
  })
})
