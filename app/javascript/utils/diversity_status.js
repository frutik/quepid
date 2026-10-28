/**
 * Plain-language text for a snapshot's diversity state, as returned by
 * GET api/cases/:case_id/snapshots/:snapshot_id/diversity (and, for the value alone, the
 * snapshot JSON). Kept out of the controllers so the wording is tested in one place.
 */

/** @param {number|null|undefined} value @returns {string} */
export function formatDiversity(value) {
  return typeof value === "number" && Number.isFinite(value) ? value.toFixed(3) : "—"
}

/**
 * One line saying where a diversity run stands.
 * @param {{ running?: boolean, diversity?: number|null, diversity_meta?: object|null, stale?: boolean }} state
 * @returns {{ text: string, tone: "muted"|"success"|"warning"|"danger" }}
 */
export function describeDiversity(state) {
  const meta = state?.diversity_meta
  if (state?.running) return { text: "Computing diversity…", tone: "muted" }
  if (!meta) return { text: "Not computed yet.", tone: "muted" }

  const detail = (meta.errors || [])[0]
  switch (meta.status) {
    case "done":
      return describeDone(state, meta)
    case "running":
      return { text: "Computing diversity…", tone: "muted" }
    case "no_embedder":
      return { text: "The case has no embedder.", tone: "danger" }
    case "no_title_field":
      return {
        text: "The try's field spec has no title field. Set one, for example title:name.",
        tone: "danger"
      }
    case "no_fields":
      return {
        text: "This snapshot has no document fields. Take a snapshot with “Record document fields” ticked.",
        tone: "danger"
      }
    case "too_large":
      return { text: `Too many new documents to embed. ${detail || ""}`.trim(), tone: "danger" }
    default:
      return { text: `Computing diversity failed. ${detail || ""}`.trim(), tone: "danger" }
  }
}

function describeDone(state, meta) {
  const scored = meta.queries_scored ?? 0
  const parts = [
    `Diversity@${meta.depth}: ${formatDiversity(state.diversity)}`,
    `${scored} ${scored === 1 ? "query" : "queries"} scored`
  ]
  if (meta.queries_skipped) parts.push(`${meta.queries_skipped} skipped`)
  if (meta.docs_without_text) parts.push(`${meta.docs_without_text} documents without a title`)
  if ((meta.errors || []).length > 0) parts.push(`errors: ${meta.errors.join("; ")}`)

  let text = parts.join(" · ")
  if (state.stale) text += " — outdated: the embedder or depth changed since."
  const tone = state.stale || (meta.errors || []).length > 0 ? "warning" : "success"
  return { text, tone }
}

/**
 * Tooltip text for a snapshot's diversity: how it was made.
 * @param {object|null|undefined} meta a snapshot's diversity_meta
 */
export function diversityTooltip(meta) {
  if (!meta || meta.status !== "done") return ""
  return `Diversity@${meta.depth} of “${meta.title_field}”, embedded with ${meta.embedder_name}`
}

/**
 * Whether the given snapshots' diversity values were made the same way, so they can be
 * compared. Snapshots without a finished value are ignored.
 * @param {Array<object|null|undefined>} metas their diversity_meta
 */
export function diversityComparable(metas) {
  const done = (metas || []).filter((meta) => meta?.status === "done")
  if (done.length < 2) return true

  const key = (meta) => [meta.fingerprint, meta.title_field, meta.depth].join("\u0000")
  return done.every((meta) => key(meta) === key(done[0]))
}
