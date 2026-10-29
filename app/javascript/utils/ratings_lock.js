/**
 * Locks the rating controls while the case's scorer never reads ratings (ILD): they stay on the
 * page, dimmed and disabled, with a tooltip saying why, so ratings already given stay visible
 * and nothing shifts when the scorer changes. Blocking clicks is CSS (`pointer-events`, in
 * core-additions.css, keyed on NO_RATINGS_CLASS), which also lets the tooltip on the wrapper
 * show; the buttons are `disabled` as well, for the keyboard.
 *
 * Controls are rendered lazily, from templates, as queries are shown, so `setRatingsLocked` only
 * covers those on the page when the scorer changes. The controllers that create them
 * (rating-popover, missing-documents) call `lockIfRatingsUnused` when they connect.
 */
export const NO_RATINGS_CLASS = "scorer-no-ratings"
export const NO_RATINGS_MESSAGE = "The current scorer doesn't use ratings"

const LOCK_ATTRIBUTE = "data-ratings-locked"
// A wrapper for the tooltip, and the buttons inside it (or it, when it is the button).
const RATING_WRAPPERS = ".col-ratings"
const MISSING_DOCUMENTS = '[data-slot="missingDocuments"]'

export function ratingsUnused() {
  return Boolean(document.body?.classList.contains(NO_RATINGS_CLASS))
}

function lock(wrapper, buttons) {
  wrapper.title = NO_RATINGS_MESSAGE
  wrapper.setAttribute(LOCK_ATTRIBUTE, "true")
  buttons.forEach((button) => {
    // One that is disabled for another reason stays that way, and isn't ours to enable later.
    if (button.disabled) return
    button.disabled = true
    button.setAttribute(LOCK_ATTRIBUTE, "true")
  })
}

function unlock(wrapper, buttons) {
  if (wrapper.getAttribute(LOCK_ATTRIBUTE) === "true") {
    wrapper.removeAttribute("title")
    wrapper.removeAttribute(LOCK_ATTRIBUTE)
  }
  buttons.forEach((button) => {
    if (button.getAttribute(LOCK_ATTRIBUTE) !== "true") return
    button.disabled = false
    button.removeAttribute(LOCK_ATTRIBUTE)
  })
}

function controls(root) {
  const rating = [...root.querySelectorAll(RATING_WRAPPERS)].map((wrapper) => ({
    wrapper,
    buttons: [...wrapper.querySelectorAll("button")]
  }))
  const missing = [...root.querySelectorAll(MISSING_DOCUMENTS)].map((button) => ({
    wrapper: button.parentElement,
    buttons: [button]
  }))
  return [...rating, ...missing]
}

/** Sets the page-wide state and applies it to the controls already on the page. */
export function setRatingsLocked(locked, root = document) {
  document.body?.classList.toggle(NO_RATINGS_CLASS, locked)
  controls(root).forEach(({ wrapper, buttons }) => (locked ? lock : unlock)(wrapper, buttons))
}

/** For a control that has just been rendered: locks it if the scorer doesn't use ratings. */
export function lockIfRatingsUnused(element) {
  if (!ratingsUnused() || !element) return

  const wrapper = element.closest(RATING_WRAPPERS)
  if (wrapper) return lock(wrapper, [...wrapper.querySelectorAll("button")])
  if (element.matches?.(MISSING_DOCUMENTS)) lock(element.parentElement, [element])
}
