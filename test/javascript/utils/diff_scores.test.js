import { describe, expect, it } from "vitest"
import { buildCaseDiffScores } from "utils/diff_scores"

function searcher(name, version, score) {
  return {
    name: () => name,
    version: () => version,
    diffScore: score
  }
}

function query(searchers) {
  return {
    diffs: {
      getSearchers: () => searchers,
      getSearcher: (index) => searchers[index]
    }
  }
}

describe("buildCaseDiffScores", () => {
  it("averages each snapshot position and preserves metadata", () => {
    const baseline = searcher("Baseline", 3, { score: 0.5, allRated: true })
    const tuned = searcher("Tuned", 4, { score: 1, allRated: false })

    expect(
      buildCaseDiffScores(
        [
          query([baseline, tuned]),
          query([
            searcher("Baseline", 3, { score: 1, allRated: true }),
            searcher("Tuned", 4, { score: 0.5, allRated: true })
          ])
        ],
        1
      )
    ).toEqual([
      {
        name: "Baseline",
        version: 3,
        diversity: null,
        score: {
          score: 0.75,
          maxScore: 1,
          allRated: true,
          backgroundColor: expect.any(String)
        }
      },
      {
        name: "Tuned",
        version: 4,
        diversity: null,
        score: {
          score: 0.75,
          maxScore: 1,
          allRated: false,
          backgroundColor: expect.any(String)
        }
      }
    ])
  })

  it("ignores unrated and missing scores, returning the pending sentinel when needed", () => {
    const scores = buildCaseDiffScores(
      {
        first: query([searcher("Baseline", 1, { score: "--", allRated: false })]),
        second: query([searcher("Baseline", 1, { score: null, allRated: true })])
      },
      2
    )

    expect(scores[0].score).toMatchObject({
      score: "--",
      maxScore: 2,
      allRated: false
    })
  })

  it("returns no read model when no query has diffs", () => {
    expect(buildCaseDiffScores([{ diffs: null }])).toEqual([])
  })

  it("carries each snapshot's diversity along with its score", () => {
    const snapshot = { diversity: 0.4, diversityMeta: { status: "done" }, diversityStale: true }
    const withDiversity = { ...searcher("Baseline", 3, { score: 0.5, allRated: true }), snapshot }
    const without = searcher("Tuned", 4, { score: 1, allRated: true })

    const [first, second] = buildCaseDiffScores([query([withDiversity, without])])

    expect(first.diversity).toEqual({ value: 0.4, meta: { status: "done" }, stale: true })
    expect(second.diversity).toBeNull()
  })
})
