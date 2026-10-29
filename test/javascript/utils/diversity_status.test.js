import { describe, expect, it } from "vitest"
import {
  describeDiversity,
  diversityComparable,
  diversityTooltip,
  formatDiversity
} from "utils/diversity_status"

const DONE = {
  status: "done",
  depth: 10,
  fingerprint: "abc",
  title_field: "name",
  embedder_name: "Voyage 1024",
  queries_scored: 48,
  queries_skipped: 2,
  docs_without_text: 0,
  errors: []
}

describe("formatDiversity", () => {
  it("prints three decimals, and a dash when there is no value", () => {
    expect(formatDiversity(0.41234)).toBe("0.412")
    expect(formatDiversity(0)).toBe("0.000")
    expect(formatDiversity(null)).toBe("—")
    expect(formatDiversity(undefined)).toBe("—")
    expect(formatDiversity(Number.NaN)).toBe("—")
  })
})

describe("describeDiversity", () => {
  it("says nothing was computed yet", () => {
    expect(describeDiversity({ diversity_meta: null })).toEqual({
      text: "Not computed yet.",
      tone: "muted"
    })
  })

  it("says a run is under way, whatever the stored meta says", () => {
    expect(describeDiversity({ running: true, diversity_meta: DONE }).text).toBe(
      "Computing diversity…"
    )
    expect(describeDiversity({ diversity_meta: { status: "running" } }).text).toBe(
      "Computing diversity…"
    )
  })

  it("summarises a finished run", () => {
    const { text, tone } = describeDiversity({ diversity: 0.4567, diversity_meta: DONE })

    expect(text).toBe("Diversity@10: 0.457 · 48 queries scored · 2 skipped")
    expect(tone).toBe("success")
  })

  it("flags an outdated value", () => {
    const { text, tone } = describeDiversity({
      diversity: 0.4,
      stale: true,
      diversity_meta: DONE
    })

    expect(text).toContain("outdated")
    expect(tone).toBe("warning")
  })

  it("reports errors from a partly failed run", () => {
    const { text, tone } = describeDiversity({
      diversity: 0.4,
      diversity_meta: { ...DONE, errors: ["Voyage API error: 500"] }
    })

    expect(text).toContain("errors: Voyage API error: 500")
    expect(tone).toBe("warning")
  })

  it("says how to fix each way a run can stop", () => {
    const text = (status, errors = []) =>
      describeDiversity({ diversity_meta: { status, errors } }).text

    expect(text("no_fields")).toContain("Record document fields")
    expect(text("no_title_field")).toContain("title:name")
    expect(text("no_embedder")).toContain("no embedder")
    expect(text("too_large", ["6000 documents to embed"])).toContain("6000 documents")
    expect(text("failed", ["boom"])).toBe("Computing diversity failed. boom")
  })
})

describe("diversityTooltip", () => {
  it("names the field and embedder of a finished value", () => {
    expect(diversityTooltip(DONE)).toBe("Diversity@10 of “name”, embedded with Voyage 1024")
    expect(diversityTooltip({ status: "failed" })).toBe("")
    expect(diversityTooltip(null)).toBe("")
  })
})

describe("diversityComparable", () => {
  it("is true when the values were made the same way", () => {
    expect(diversityComparable([DONE, { ...DONE, queries_scored: 3 }])).toBe(true)
  })

  it("is false when the embedder, title field or depth differ", () => {
    expect(diversityComparable([DONE, { ...DONE, fingerprint: "other" }])).toBe(false)
    expect(diversityComparable([DONE, { ...DONE, title_field: "label" }])).toBe(false)
    expect(diversityComparable([DONE, { ...DONE, depth: 5 }])).toBe(false)
  })

  it("ignores snapshots without a finished value", () => {
    expect(diversityComparable([DONE, null, { status: "failed" }])).toBe(true)
    expect(diversityComparable([])).toBe(true)
    expect(diversityComparable(undefined)).toBe(true)
  })
})
