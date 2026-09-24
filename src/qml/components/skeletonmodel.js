// Skeleton loading flow as a pure state machine over a ListModel.
//
// Invariants (tested in tests/qml/tst_loadflow.qml):
//  1. Placeholders are seeded ONCE, sized to the viewport.
//  2. Result batches CONSUME placeholders in place (delegates survive ->
//     SkeletonText morphs); leftover placeholders are NOT trimmed between
//     batches — they are the reason a follow-up page gets fetched.
//  3. The model count never shrinks mid-flow; the ONLY shrink is a single
//     final trim when the source runs out of results.
//  4. acceptBatch tells the caller whether another page is needed to
//     resolve remaining placeholders.
.pragma library

function blank() {
    return { placeholder: true, vid: "", title: "", channel: "",
             duration: 0, thumbnail: "", src: "youtube",
             isPlaylist: false, videoCount: 0, views: "", age: "" }
}

function toRow(r) {
    return { placeholder: false, vid: r.id, title: r.title,
             channel: r.channel || "", duration: r.duration || 0,
             views: r.views || "", age: r.age || "",
             thumbnail: r.thumbnail || "", src: r.src || "youtube",
             isPlaylist: r.isPlaylist === true, videoCount: r.videoCount || 0 }
}

function seed(model, count) {
    model.clear()
    for (let i = 0; i < count; i++) model.append(blank())
}

// Start a load: seed `count` placeholders, return flow state.
function beginLoad(model, count) {
    seed(model, count)
    return { fill: 0 }
}

// Starts a pagination load: appends `count` placeholders after existing rows
// (grids size it to finish the partial row plus one full row, so batches always
// over-fill and no mid-flow trim happens). Staged over two turns because each
// placeholder builds a fill chain: 14 in one frame stalled 400ms. Lays down
// `firstChunk` now and returns the remainder for `addBlanks` on a later turn.
function beginAppend(model, count, firstChunk) {
    const start = model.count
    const now = firstChunk === undefined ? count : Math.max(1, Math.min(firstChunk, count))
    for (let i = 0; i < now; i++) model.append(blank())
    return { fill: start, rest: count - now }
}

// The rest of a staged beginAppend. Safe at any time: acceptBatch fills from
// state.fill and appends past the end, so late placeholders are consumed by
// the same flow, and the trim only ever runs when the source is exhausted.
function addBlanks(model, n) {
    for (let i = 0; i < n; i++) model.append(blank())
}

// Tiles per turn for a tail: 6 or fewer in one turn (a narrow grid's 3-4 cost
// nothing, and splitting them only dribbles), otherwise two even halves so no
// turn adds a lone tile.
function paginationChunk(tail) {
    if (tail <= 6) return tail
    return Math.ceil(tail / 2)
}

// Feed a result batch into the flow. Fills placeholders in place from
// state.fill, appends overflow, and ONLY trims when hasMore is false.
// Returns true when the caller should fetch another page (placeholders
// remain unresolved and the source has more).
function acceptBatch(model, state, rows, hasMore) {
    for (let i = 0; i < rows.length; i++) {
        const t = state.fill + i
        if (t < model.count) model.set(t, toRow(rows[i]))
        else model.append(toRow(rows[i]))
    }
    state.fill += rows.length
    if (!hasMore) {
        while (model.count > state.fill) model.remove(model.count - 1)
        return false
    }
    return state.fill < model.count
}

// One-shot convenience (single-batch sources: playlists, library seeds).
function apply(model, rows) {
    const st = { fill: 0 }
    acceptBatch(model, st, rows, false)
}

function placeholdersLeft(model, state) {
    return Math.max(0, model.count - state.fill)
}

// ---- count math (invariant: grid counts are ALWAYS multiples of the
// column count, so skeletons never leave a partial row) ----

function gridCols(width, growth) {
    // mirror of the views' column math (width-scaled minimum tile size);
    // growth = GridUi.growth, threaded by callers (pure library, no QML)
    const availW = width - 32
    const g = growth === undefined ? 4 : growth
    return Math.max(1, Math.floor(availW / (168 + availW * g / 100)))
}

// placeholders needed to fill a viewport in the given layout
function fillCount(layout, width, height, growth) {
    if (height <= 0) return 12   // not laid out yet
    if (layout === "grid") {
        const cols = gridCols(width, growth)
        const cellW = Math.floor((width - 32) / cols)
        const cellH = Math.floor((cellW - 8) * 9 / 16) + 70
        const rows = Math.max(1, Math.ceil(height / cellH))
        return cols * Math.min(rows, Math.max(1, Math.floor(60 / cols)))
    }
    return Math.min(60, Math.max(1, Math.ceil(height / (layout === "compact" ? 28 : 54))))
}

// pagination tail: completes the grid's partial row + one full row
// (3 rows for lists); count + tail is always a multiple of the columns
function paginationTail(layout, width, currentCount, growth, cols) {
    if (layout !== "grid") return 3
    // Prefer the view's own column count: gridCols drifts from the view (fixed 168
    // vs Theme.art(), width-32 vs real padding), and a wrong `cols` leaves the row
    // incomplete.
    const c = cols === undefined || cols <= 0 ? gridCols(width, growth) : cols
    const partial = currentCount % c
    return ((c - partial) % c) + c
}
