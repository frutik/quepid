import { describe, expect, it } from "vitest"
import fs from "node:fs"
import path from "node:path"
// By file path: splainer-search's package exports don't expose services/ directly.
import { fieldSpecSvcConstructor } from "../../node_modules/splainer-search/services/fieldSpecSvc.js"

// The browser side of the cases in test/fixtures/files/field_spec_cases.json; the Ruby
// port (FieldSpec, used to pick the text embedded per document) runs the same cases in
// test/models/field_spec_test.rb. A failure here means the fixture no longer describes
// what the browser does.
const fixture = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, "../fixtures/files/field_spec_cases.json"), "utf8")
)

const svc = new fieldSpecSvcConstructor({
  safeForEach: (list, fn) => {
    if (Array.isArray(list)) list.forEach(fn)
  }
})

describe("splainer-search field specs match test/fixtures/files/field_spec_cases.json", () => {
  fixture.cases.forEach((testCase) => {
    it(`${testCase.name}`, () => {
      const fieldSpec = svc.createFieldSpec(testCase.spec)

      expect(fieldSpec.id).toEqual(testCase.id)
      expect(fieldSpec.title).toEqual(testCase.title)
    })
  })
})
