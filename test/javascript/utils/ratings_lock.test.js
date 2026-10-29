import { afterEach, beforeEach, describe, expect, it } from "vitest"
import {
  lockIfRatingsUnused,
  NO_RATINGS_CLASS,
  NO_RATINGS_MESSAGE,
  ratingsUnused,
  setRatingsLocked
} from "utils/ratings_lock"

// The shapes the templates and search_result_controller produce.
function page() {
  document.body.innerHTML = `
    <div class="sub-results">
      <div class="col-ratings query-rating"><div class="single-rating"><button class="btn">-- </button></div></div>
      <div class="search-result">
        <div class="col-ratings"><div class="single-rating"><button class="btn">1 </button></div></div>
      </div>
      <div class="btn-group"><button class="btn" data-slot="missingDocuments">Missing Documents</button></div>
    </div>`
  return {
    wrappers: [...document.querySelectorAll(".col-ratings")],
    buttons: [...document.querySelectorAll(".col-ratings button")],
    missing: document.querySelector('[data-slot="missingDocuments"]')
  }
}

describe("ratings lock", () => {
  beforeEach(() => {
    document.body.className = ""
  })

  afterEach(() => {
    document.body.innerHTML = ""
    document.body.className = ""
  })

  it("disables every rating control and explains why, wrapper and all", () => {
    const { wrappers, buttons, missing } = page()

    setRatingsLocked(true)

    expect(ratingsUnused()).toBe(true)
    expect(document.body.classList.contains(NO_RATINGS_CLASS)).toBe(true)
    wrappers.forEach((wrapper) => expect(wrapper.title).toBe(NO_RATINGS_MESSAGE))
    buttons.forEach((button) => expect(button.disabled).toBe(true))
    expect(missing.disabled).toBe(true)
    expect(missing.parentElement.title).toBe(NO_RATINGS_MESSAGE)
  })

  it("puts everything back when an ordinary scorer is chosen", () => {
    const { wrappers, buttons, missing } = page()
    setRatingsLocked(true)

    setRatingsLocked(false)

    expect(ratingsUnused()).toBe(false)
    wrappers.forEach((wrapper) => expect(wrapper.hasAttribute("title")).toBe(false))
    buttons.forEach((button) => expect(button.disabled).toBe(false))
    expect(missing.disabled).toBe(false)
    expect(missing.parentElement.hasAttribute("title")).toBe(false)
  })

  it("leaves a button that was disabled for another reason disabled", () => {
    const { buttons } = page()
    buttons[1].disabled = true

    setRatingsLocked(true)
    setRatingsLocked(false)

    expect(buttons[0].disabled).toBe(false)
    expect(buttons[1].disabled).toBe(true)
  })

  it("does not take a title it didn't set", () => {
    const { wrappers } = page()

    setRatingsLocked(false)

    expect(wrappers[0].hasAttribute("title")).toBe(false)
  })

  it("locks a control rendered later, but only while the scorer doesn't use ratings", () => {
    page()
    const late = document.createElement("div")
    late.className = "col-ratings"
    late.innerHTML = '<div class="single-rating"><button class="btn">0 </button></div>'
    document.body.append(late)

    lockIfRatingsUnused(late.firstElementChild)
    expect(late.querySelector("button").disabled).toBe(false)

    setRatingsLocked(true)
    const later = late.cloneNode(true)
    later.removeAttribute("title")
    later.querySelector("button").disabled = false
    document.body.append(later)
    lockIfRatingsUnused(later.firstElementChild)

    expect(later.title).toBe(NO_RATINGS_MESSAGE)
    expect(later.querySelector("button").disabled).toBe(true)
  })

  it("locks a Missing Documents button rendered later", () => {
    const { missing } = page()
    setRatingsLocked(false)

    setRatingsLocked(true)
    const fresh = missing.cloneNode(true)
    fresh.disabled = false
    missing.parentElement.append(fresh)
    lockIfRatingsUnused(fresh)

    expect(fresh.disabled).toBe(true)
  })

  it("ignores elements that are not rating controls", () => {
    page()
    setRatingsLocked(true)
    const other = document.createElement("button")
    document.body.append(other)

    lockIfRatingsUnused(other)
    lockIfRatingsUnused(null)

    expect(other.disabled).toBe(false)
  })
})
