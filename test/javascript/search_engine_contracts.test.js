import { describe, expect, it } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { createFetchClient, createWiredServices } from "splainer-search/wired.js"
import { createSearcherFromSettings, normalizeSearchResults } from "utils/query_service"
import { buildRatedDocsFilter } from "utils/rated_docs"
import { isEsLikeEngine } from "utils/search_engines"

// The browser side of test/fixtures/files/search_engine_contracts/*.json; the server side
// (FetchService) runs the same fixtures in test/services/search_engine_contracts_test.rb.
// Characterization tests: they pin what each engine sends and how its response is read
// today, through the real splainer-search with only fetch faked, so moving the engines to
// one architecture can be checked against them. A failure means the behaviour changed.
const fixtureDir = path.resolve(__dirname, "../fixtures/files/search_engine_contracts")
const engines = ["solr", "es"]

// The same shape the Ruby side builds: params grouped by key, JSON body parsed.
function canonicalRequest(url, init) {
  const parsed = new URL(url)
  const params = {}
  parsed.searchParams.forEach((value, key) => {
    ;(params[key] ||= []).push(value)
  })
  return {
    method: init.method,
    url: `${parsed.origin}${parsed.pathname}`,
    params,
    body: init.body ? JSON.parse(init.body) : null
  }
}

async function runBrowserSearch(fixture) {
  const requests = []
  const fakeFetch = async (url, init) => {
    requests.push(canonicalRequest(url, init))
    return new Response(JSON.stringify(fixture.response), {
      status: 200,
      headers: { "Content-Type": "application/json" }
    })
  }
  const services = createWiredServices(createFetchClient({ fetch: fakeFetch }))

  // escapeQuery: true is the try's database default (tries.escape_query).
  const settings = {
    searchEngine: fixture.search_engine,
    apiMethod: fixture.api_method,
    numberOfRows: fixture.number_of_rows,
    escapeQuery: true,
    selectedTry: { searchUrl: fixture.search_url, args: fixture.expected.args },
    createFieldSpec: () => services.fieldSpecSvc.createFieldSpec(fixture.field_spec)
  }
  // The query model's filterToRatings, with the docs in the recorded response as its ratings.
  const query = {
    queryText: fixture.query_text,
    options: {},
    filterToRatings: (s) =>
      buildRatedDocsFilter({
        searchEngine: s.searchEngine,
        idField: s.createFieldSpec().id,
        ratedIds: ["11", "1891"]
      })
  }
  const newSearcher = (options) =>
    createSearcherFromSettings({
      settings,
      query,
      options,
      isEsOrOs: isEsLikeEngine(fixture.search_engine),
      createSearcher: (...args) => services.searchSvc.createSearcher(...args)
    })

  const searcher = newSearcher()
  await searcher.search()
  // Peek at the next page (query_runtime.js's paginate), then "Show only rated".
  await searcher.pager().search()
  await newSearcher({ filterToRated: true }).search()

  const docs = normalizeSearchResults({
    searcher,
    fieldSpec: settings.createFieldSpec(),
    extractors: {
      es: (docs, spec) => services.esExplainExtractorSvc.docsWithExplainOther(docs, spec),
      solr: (docs, spec, othersExplained) =>
        services.solrExplainExtractorSvc.docsWithExplainOther(docs, spec, othersExplained)
    },
    createNormalDoc: (spec, doc, explain) =>
      services.normalDocsSvc.createNormalDoc(spec, doc, explain),
    createRateableDoc: (doc) => doc
  })

  return {
    requests: { search: requests[0], next_page: requests[1], rated_only: requests[2] },
    num_found: searcher.numFound,
    docs: docs.map((doc) => ({
      id: doc.id,
      title: doc.title,
      subs: doc.subs,
      score: doc.score(),
      hot_matches: doc.hotMatches().vecObj
    }))
  }
}

describe("search engine contracts (browser, splainer-search)", () => {
  engines.forEach((engine) => {
    const fixture = JSON.parse(fs.readFileSync(path.join(fixtureDir, `${engine}.json`), "utf8"))

    it(`${engine}: sends the recorded request and reads the recorded response`, async () => {
      const actual = await runBrowserSearch(fixture)
      // DUMP_CONTRACTS=1 writes the actual output, to re-record a fixture after an intended change.
      if (process.env.DUMP_CONTRACTS) {
        fs.mkdirSync("tmp/contracts", { recursive: true })
        fs.writeFileSync(`tmp/contracts/${engine}.browser.json`, JSON.stringify(actual, null, 2))
      }

      expect(actual).toEqual(fixture.expected.browser)
    })
  })
})
