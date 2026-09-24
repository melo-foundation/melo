.pragma library

// What a bar cell is called. One answer, used by the renderer to tell an edit
// from a replacement and by the arranger to address a cell it is editing, so
// the editor and the thing it edits name a cell the same way.

// Keyed on kind, not the whole document, so an edited cell diffs as the same
// cell instead of a remove and an insert. Spacers are the exception: a row may
// hold several, so a spacer is keyed on its whole document, which is its width
// (a spacer has no state to lose on rebuild).
function cellKey(c) {
    const t = c.type || "spacer"
    if (t === "button") return "button:" + (c.id || "")
    if (t !== "spacer") return t
    const o = {}
    for (const k of Object.keys(c).sort()) if (k !== "_drag") o[k] = c[k]
    return "spacer:" + JSON.stringify(o)
}

// a row's cells, in order, with the copies of one kind numbered apart
function cellKeys(cells) {
    const seen = {}
    return (cells || []).map(function (c) {
        const k = cellKey(c)
        const n = seen[k] = (seen[k] || 0) + 1
        return n > 1 ? k + "#" + n : k
    })
}

function indexOfKey(cells, key) {
    const ks = cellKeys(cells)
    for (let i = 0; i < ks.length; ++i) if (ks[i] === key) return i
    return -1
}

// Which shelf element a cell came from — a different question from which cell
// it is. The disc and the plain play button are one element with a knob, so
// they answer the same here and differently above.
// A title without its artist is the Title element; with one, Title + artist.
function elementKey(c) {
    return c.type === "button" ? "button:" + c.id
         : c.type === "playdisc" ? "play"
         : c.type === "title" && c.artist === "none" ? "title:only"
         : c.type
}

// What is picked, as one string: a row by its index, a cell by its identity
// within its row. A cell key may contain a comma — a spacer's is its document —
// so the two are told apart by their prefix and never by punctuation.
function rowPick(r) { return "row:" + r }
function cellPick(r, key) { return "cell:" + r + ":" + key }
function isRow(p) { return p.lastIndexOf("row:", 0) === 0 }
function isCell(p) { return p.lastIndexOf("cell:", 0) === 0 }
function pickRow(p) {
    if (isRow(p)) return Number(p.slice(4))
    if (!isCell(p)) return -1
    const rest = p.slice(5), colon = rest.indexOf(":")
    return colon < 0 ? -1 : Number(rest.slice(0, colon))
}
function pickKey(p) {
    if (!isCell(p)) return ""
    const rest = p.slice(5), colon = rest.indexOf(":")
    return colon < 0 ? "" : rest.slice(colon + 1)
}
