import QtQuick
import ".."

// A bar from a document: rows of cells, stacked from the top or centred
// in the bar, one row allowed on the bottom edge; a variant's rows under
// its width. The only thing that draws a player bar. The document is
// `docs/bar-layout.md`.
Item {
    id: lay
    property var doc: ({})
    property var bar
    signal laidOut()   // a row laid its cells out: what asks where things are may ask again
    // READY when every row has laid its cells out at least once; ON SCREEN
    // at the first frame the window swaps after that — Qt's frameSwapped is
    // the last signal of a rendered frame, so this is "drawn", not a guess
    readonly property bool ready: {
        const dep = rowGen, r0 = rep()
        if (r0.count === 0 || r0.count !== rowDocs.length) return false
        for (let i = 0; i < r0.count; ++i) { const r = r0.itemAt(i); if (!r || !r.laid) return false }
        return true
    }
    property bool onScreen: false
    // an unexposed window swaps nothing: ready counts as on screen there
    // FrameClock is the app's; a test has none, and there ready is on screen
    readonly property var clock: typeof FrameClock !== "undefined" ? FrameClock : null
    onReadyChanged: {
        if (!ready) { onScreen = false; return }
        if (!clock || (Window.window && !clock.exposed(Window.window.title))) onScreen = true
    }
    Connections {
        target: lay.ready && !lay.onScreen ? lay.clock : null
        function onSwapped(title) { if (lay.Window.window && title === lay.Window.window.title) lay.onScreen = true }
    }
    // the rows in force: the first variant the bar is narrower than, else the document's
    readonly property var variant: {
        const vs = doc.variants || []
        for (const v of vs) if (width < (v.maxWidth === "narrow" ? GridUi.narrowW : v.maxWidth)) return v
        return null
    }
    readonly property var rowDocs: variant && variant.rows ? variant.rows : (doc.rows || [])
    // MELO_BAR_DEBUG=1: which arrangement this renderer is on and why. The
    // wide arrangement showing for a frame between two bars is an `alt` that
    // went false — either the width crossed the threshold, or the document
    // arrived without the variants it should have had.
    function _dbg(why) {
        if (typeof MELO_BAR_DEBUG === "undefined" || !MELO_BAR_DEBUG) return
        console.warn("[bar] " + (typeof key !== "undefined" ? key : "?") + " " + why
                     + " w=" + Math.round(width) + " alt=" + alt + " fade=" + fade.toFixed(2)
                     + " variants=" + ((doc.variants || []).length)
                     + " rows=" + rowDocs.length + " h=" + Math.round(docHeight))
    }
    onWidthChanged: _dbg("width")
    onAltChanged: _dbg("ALT")
    onDocChanged: _dbg("doc")
    onFadeChanged: _dbg("fade")
    // The two arrangements, both built: the document's rows and the last
    // variant's, so crossing the threshold crossfades them on the move token
    // instead of rebuilding every row mid-resize. The variant set keeps the
    // last variant that applied, so leaving and re-entering it builds nothing.
    readonly property bool alt: variant !== null
    property var altDoc: variant
    onVariantChanged: if (variant) altDoc = variant
    readonly property var altRows: altDoc && altDoc.rows ? altDoc.rows : []
    function rep() { return alt ? repAlt : repMain }
    property real fade: alt ? 1 : 0
    // No crossfade until the renderer has been drawn: on the document's first frame
    // `variant` has not re-evaluated, reads the wide arrangement and flips a moment
    // later. Nor while `quiet`: the handover gives the mini bar the document at the
    // old window width, and the resize that follows would crossfade the centred
    // scrubber out.
    Behavior on fade {
        enabled: lay.onScreen && !(lay.bar && lay.bar.quiet === true)
        NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase }
    }
    readonly property real docHeight: variant && variant.height !== undefined ? variant.height : (doc.height || 77)
    // A sum over the rows is evaluated when the count changes, before the
    // rows exist, and so captures nothing to re-evaluate on; the rows bump
    // this when their height or emptiness changes, and the sums read it.
    property int rowGen: 0
    // less the rows that are empty and not being arranged
    readonly property real collapsedH: {
        const dep = rowGen, r0 = rep()
        let h = 0
        for (let i = 0; i < r0.count; ++i) { const r = r0.itemAt(i); if (r && r.collapsed && !r.onEdge) h += (r.rowH + rowGap) }
        return h
    }
    readonly property real barHeight: Theme.bar(Math.max(24, docHeight - collapsedH))
    // A bar on its way out keeps its padding, frozen like its height: `backing` is
    // not animated and flips to the incoming value at once, so the outgoing cells
    // would jump sideways by the card's inset a frame before their transition.
    property real frozenEdge: -1
    property real frozenEdgeR: -1
    // Side padding: the document's `padLeft`/`padRight`, else `pad`, else the theme's
    // player inset; the floating card's inset is added on top.
    function docPad(side) {
        const own = side === "left" ? doc.padLeft : doc.padRight
        if (own !== undefined) return Number(own)
        return doc.pad !== undefined ? Number(doc.pad) : Theme.inset("player", side)
    }
    function sideEdge(side) {
        return docPad(side)
               + (bar && bar.backing === "floating" ? bar.inset : 0)
               // ...and what the window's shape cuts away at that end
               + (bar ? (side === "left" ? bar.cutLeft : bar.cutRight) : 0)
    }
    readonly property real edge: frozenEdge >= 0 ? frozenEdge : sideEdge("left")
    readonly property real edgeRight: frozenEdgeR >= 0 ? frozenEdgeR : sideEdge("right")
    // and the vertical padding the same way: `top` from the variant, then the
    // document, then the inset; the bottom is the theme's, since a document
    // says how tall it is rather than what it leaves under its rows
    readonly property real topPad: variant && variant.top !== undefined ? variant.top
                                 : (doc.top !== undefined ? doc.top : Theme.inset("player", "top"))
    readonly property real botPad: Theme.inset("player", "bottom")
    readonly property real rowGap: doc.rowGap !== undefined ? doc.rowGap : 4
    readonly property bool vcenter: doc.vcenter === true
    readonly property real vOffset: doc.vOffset || 0

    // the stacked rows' y, from their heights — each arrangement's own
    function stackYs(r0, top) {
        // On a floating card the rows sit in the card, not the bar: its top and
        // bottom insets add to the paddings the way its side inset adds to the
        // edges. They are not equal, so centring in the bar would put the rows
        // off the card's middle.
        const card = bar && bar.backing === "floating"
        top += card ? bar.cardTop : 0
        const bottom = botPad + (card ? bar.cardBottom : 0)
        const ys = []; let y = top
        const hs = []
        for (let i = 0; i < r0.count; ++i) { const r = r0.itemAt(i); hs.push(r && !r.onEdge ? r.usedH : 0) }
        // A gap only between two rows that are there, so an empty row does not
        // make the stack a gap too tall and centre everything half a gap high.
        const shown = hs.filter(h => h > 0)
        const stack = shown.reduce((a, h) => a + h, 0) + Math.max(0, shown.length - 1) * rowGap
        // centred between the paddings: equal ones centre in the bar
        if (vcenter) y = top + (height - top - bottom - stack) / 2 + vOffset
        for (let i = 0; i < hs.length; ++i) { ys.push(y); if (hs[i] > 0) y += hs[i] + rowGap }
        return ys
    }
    readonly property var ysMain: { const dep = rowGen; return stackYs(repMain, doc.top !== undefined ? doc.top : Theme.inset("player", "top")) }
    readonly property var ysAlt: { const dep = rowGen; return stackYs(repAlt, altDoc && altDoc.top !== undefined ? altDoc.top : (doc.top !== undefined ? doc.top : Theme.inset("player", "top"))) }
    readonly property var rowYs: alt ? ysAlt : ysMain
    Item {
        id: setMain
        anchors.fill: parent
        opacity: 1 - lay.fade
        visible: opacity > 0.001
        Repeater {
            id: repMain
            model: (lay.doc.rows || []).length
            BarRow {
                required property int index
                doc: lay.doc.rows[index]
                bar: lay.bar
                layout: lay
                x: pad
                width: lay.width - pad - padRight
                y: onEdge ? 0 : (lay.ysMain[index] || 0)
            }
        }
    }
    Item {
        id: setAlt
        anchors.fill: parent
        opacity: lay.fade
        visible: opacity > 0.001
        Repeater {
            id: repAlt
            model: lay.altRows.length
            BarRow {
                required property int index
                doc: lay.altRows[index]
                bar: lay.bar
                layout: lay
                x: pad
                width: lay.width - pad - padRight
                y: onEdge ? 0 : (lay.ysAlt[index] || 0)
            }
        }
    }

    // for the editor and the tests: where things are
    function rowAt(i) { return rep().itemAt(i) }
    function rowCountItems() { return rep().count }
    // finish every cell's build synchronously, now
    function finish() {
        for (const r0 of [repMain, repAlt]) for (let i = 0; i < r0.count; ++i) { const r = r0.itemAt(i); if (r) r.finish() }
    }
    function cellRect(rowIndex, cellIndex, target) {
        const r = rep().itemAt(rowIndex); return r ? r.cellRect(cellIndex, target) : null
    }
    function buttonRect(id, target) {
        const r0 = rep()
        for (let i = 0; i < r0.count; ++i) {
            const r = r0.itemAt(i); if (!r) continue
            for (let j = 0; j < (r.doc.cells || []).length; ++j) {
                const c = r.cellAt(j)
                if (c && c.type === "button" && c.shown && c.children[0].item) {
                    const rr = c.children[0].item.rectOf(id, target); if (rr) return rr
                }
            }
        }
        return null
    }
    // The edge row's cell, if this arrangement has one: an "at: bottom" row is
    // the bar's whole height and lays its cells at the foot of it, so its cell
    // must sit flush with the bar's bottom edge. Reported against the layout's
    // own bottom, which is where it should be zero.
    function edgeProbe(target) {
        for (const r0 of [repMain, repAlt])
            for (let i = 0; i < r0.count; ++i) {
                const r = r0.itemAt(i)
                if (!r || !r.onEdge) continue
                const c = r.cellAt(0)
                if (!c || !c.shown) continue
                const rc = c.mapToItem(target, 0, 0, c.width, c.height)
                return Math.round(rc.y + rc.height)
            }
        return -1
    }
    // The play button's rectangle, for the swap check: it is in every layout,
    // and its distance from the bar's bottom edge is fixed for a given set of
    // rows. If that distance moves while the rows on screen have not, the bar
    // has changed size around the layout it is still showing.
    function transportRect(target) {
        const r0 = rep()
        for (let i = 0; i < r0.count; ++i) {
            const r = r0.itemAt(i); if (!r) continue
            for (let j = 0; j < (r.doc.cells || []).length; ++j) {
                const c = r.cellAt(j)
                if (c && (c.type === "play" || c.type === "playdisc") && c.shown)
                    return c.mapToItem(target, 0, 0, c.width, c.height)
            }
        }
        return null
    }
    function transportCentreX(target) {
        const r0 = rep()
        for (let i = 0; i < r0.count; ++i) {
            const r = r0.itemAt(i); if (!r) continue
            for (let j = 0; j < (r.doc.cells || []).length; ++j) {
                const c = r.cellAt(j)
                if (c && (c.type === "play" || c.type === "playdisc") && c.shown) return c.mapToItem(target, c.width / 2, 0).x
            }
        }
        return width / 2
    }
}
