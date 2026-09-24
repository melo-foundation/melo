import QtQuick
import QtQuick.Shapes
import ".."
import QtQuick.Effects
import "barkeys.js" as Keys

// One row of a bar: cells left to right with a gap, flex cells sharing what is
// left. With a centred cell, cells before it lay leftward from it and cells after
// rightward; a side with a flex cell fills its half, a side without hugs the
// centre and stops at the row's edge.
Item {
    id: row
    property var doc: ({})
    property var bar
    property var layout
    property real rowGap: doc.gap !== undefined ? doc.gap : 8
    // a row's own side padding, else the layout's. `pad` sets both sides;
    // `padLeft` and `padRight` each name one, so a row can hold its left edge
    // where the others are and still pull its right end in.
    readonly property real pad: doc.padLeft !== undefined ? Number(doc.padLeft)
                              : doc.pad !== undefined ? Number(doc.pad)
                              : (layout ? layout.edge : Theme.inset("player", "left"))
    readonly property real padRight: doc.padRight !== undefined ? Number(doc.padRight)
                                   : doc.pad !== undefined ? Number(doc.pad)
                                   : (layout ? layout.edgeRight : Theme.inset("player", "right"))
    readonly property real rowH: doc.height || 24
    // A row may be a panel. The players this bar comes from put their readout
    // on a screen — black, with the words on it in the screen's own ink — and
    // a bar that can only colour its whole deck cannot say that. `role` is the
    // surface behind this row's cells and `ink` the ink they take.
    readonly property string rowRole: doc.role !== undefined ? String(doc.role) : ""
    readonly property string rowInk: doc.ink !== undefined ? String(doc.ink) : ""
    // a row on the bar's bottom edge is the bar's whole height, so a mask
    // of the window's corners lands where the window's corners are
    readonly property bool onEdge: doc.at === "bottom"
    // how tall the things in the row are; cells that hold nothing — a spacer,
    // a group with no buttons in it — have no say
    property int cellGen: 0
    readonly property real tallest: {
        const dep = cellGen
        let h = 0
        for (let i = 0; i < rep.count; ++i) { const c = rep.itemAt(i); if (c && c.shown) h = Math.max(h, c.implicitHeight) }
        return h
    }
    // an empty row — one the document gives no cells — is room to drop into
    // while arranging, and nothing after. From the document, not from the
    // cells' loaded state, so a row whose cells are still loading does not
    // read as empty and dip the bar.
    readonly property bool empty: (doc.cells || []).length === 0
    readonly property bool collapsed: empty && !(bar && bar.customising === true)
    onCollapsedChanged: if (layout) layout.rowGen++
    onUsedHChanged: if (layout) layout.rowGen++
    Surface {
        anchors.fill: parent
        z: -1
        visible: row.rowRole.length > 0
        role: row.rowRole
        radius: row.doc.radius !== undefined ? row.doc.radius : 0
        backdrop: Theme.backdrop
    }

    // LAID once every cell is ready and the row has laid them out: until
    // then a cell is not drawn, so nothing sits at the edge for a frame
    property bool laid: false
    onLaidChanged: if (layout) layout.rowGen++
    // lay out once every cell is ready: the first time that makes the row
    // laid; after an insert it places the new cell, which was not drawn
    // until now
    function checkReady() {
        if (rep.count !== cellsModel.count) return
        for (let i = 0; i < rep.count; ++i) { const c = rep.itemAt(i); if (!c || !c.ready) return }
        relayout()
        laid = true
    }
    Component.onCompleted: { syncModel(); if ((doc.cells || []).length === 0) laid = true }
    // The cells, keyed by identity, so a new document that moves a cell moves
    // the item, one that edits a cell changes it, and only one that inserts a
    // cell builds one — the rest keep their loaders, their images, their
    // scrolling titles.
    ListModel { id: cellsModel }
    // Cell names live in barkeys.js, shared with the arranger.
    // Once the row has drawn, every change animates: an arriving cell opens where it
    // belongs, a leaving one closes at the seam, the rest glide aside.
    property bool animating: false
    Timer { id: animEnd; interval: Theme.motionMove * 2; onTriggered: row.animating = false }
    function syncModel() {
        const cells = doc.cells || []
        const morph = laid || (bar ? bar.morphing === true : false)
        if (morph) { animating = true; animEnd.restart() }
        const keys = Keys.cellKeys(cells)
        const want = new Set(keys)
        // a cell the document no longer has goes at once — or, in a morph,
        // squeezes out first and goes when the move is over
        for (let i = cellsModel.count - 1; i >= 0; --i) {
            const e = cellsModel.get(i)
            if (want.has(e.key)) { if (e.leaving) cellsModel.setProperty(i, "leaving", false); continue }
            if (!morph) { cellsModel.remove(i); continue }
            if (!e.leaving) {
                cellsModel.setProperty(i, "leaving", true)
                cellsModel.setProperty(i, "docJson", JSON.stringify(Object.assign(JSON.parse(e.docJson), { _leave: true })))
                purge.restart()
            }
        }
        // the wanted cells in order, passing over the ones on their way out
        let m = 0
        for (let i = 0; i < keys.length; ++i) {
            while (m < cellsModel.count && cellsModel.get(m).leaving) m++
            let j = -1
            for (let k = m; k < cellsModel.count; ++k) if (cellsModel.get(k).key === keys[i]) { j = k; break }
            const js = JSON.stringify(cells[i])
            if (j < 0) cellsModel.insert(m, { key: keys[i], docJson: js, leaving: false })
            else {
                if (j !== m) cellsModel.move(j, m, 1)
                if (cellsModel.get(m).docJson !== js) cellsModel.setProperty(m, "docJson", js)
            }
            m++
        }
    }
    Timer {
        id: purge
        interval: Theme.motionMove + 60
        onTriggered: {
            for (let i = cellsModel.count - 1; i >= 0; --i) if (cellsModel.get(i).leaving) cellsModel.remove(i)
            row.later()
        }
    }
    // The row's height is a ceiling on what its cells may take; with nothing measured
    // yet (cells building, or only spacers) the stated height stands. `padTop` and
    // `padBottom` (px) deepen a panel row past its cells so a plate's drop sits
    // inside it, and count toward the ceiling.
    readonly property real padTop: doc.padTop > 0 ? Number(doc.padTop) : 0
    readonly property real padBottom: doc.padBottom > 0 ? Number(doc.padBottom) : 0
    readonly property real usedH: collapsed ? 0 : (tallest > 0 ? Math.min(rowH, tallest + padTop + padBottom) : rowH)
    height: onEdge ? (layout ? layout.height : usedH) : usedH

    layer.enabled: onEdge && (bar ? bar.edgeRadius : Theme.windowRadius) > 0
    layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: cornerMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
    Item {
        id: cornerMask
        visible: false
        anchors.fill: parent
        layer.enabled: true
        Rectangle { anchors.fill: parent; color: "#ffffff"
                    bottomLeftRadius: bar ? bar.edgeRadius : Theme.windowRadius
                    bottomRightRadius: bar ? bar.edgeRadius : Theme.windowRadius }
    }

    function cellRect(index, target) {
        const c = rep.itemAt(index)
        return c && c.shown ? c.mapToItem(target, 0, 0, c.width, c.height) : null
    }
    function cellAt(index) { return rep.itemAt(index) }
    function cellCount() { return rep.count }
    function finish() { for (let i = 0; i < rep.count; ++i) { const c = rep.itemAt(i); if (c) c.finish() } }

    // The plate a run of cells sits on: a pale backing that swells around each button
    // and pinches between them. Cells naming the same `backing` share one, from the
    // first's left edge to the last's right.
    property int backGen: 0
    readonly property var backings: {
        const dep = backGen + cellGen
        const out = []
        let run = null
        for (let i = 0; i < rep.count; ++i) {
            const c = rep.itemAt(i)
            const name = c && c.shown && c.doc.backing !== undefined ? String(c.doc.backing) : ""
            if (run && run.role !== name) { out.push(run); run = null }
            if (name.length === 0) continue
            const pad = c.doc.backingPad !== undefined ? Number(c.doc.backingPad) : 0
            // the tail is the run's, named on any cell of it; the last word wins
            const tail = c.doc.backingTail !== undefined ? Number(c.doc.backingTail) : -1
            if (!run) run = ({ role: name, pad: pad, radius: c.doc.backingRadius,
                               neck: c.doc.backingNeck !== undefined ? Number(c.doc.backingNeck) : 0,
                               drop: c.doc.backingDrop !== undefined ? Number(c.doc.backingDrop) : 0,
                               tail: tail > 0 ? tail : 0,
                               parts: [({ x: c.x, y: c.y, w: c.width, h: c.implicitHeight })],
                               x: c.x, right: c.x + c.width,
                               y: c.y, bottom: c.y + c.implicitHeight })
            else {
                run.parts.push({ x: c.x, y: c.y, w: c.width, h: c.implicitHeight })
                run.right = Math.max(run.right, c.x + c.width)
                run.x = Math.min(run.x, c.x)
                run.y = Math.min(run.y, c.y)
                run.bottom = Math.max(run.bottom, c.y + c.implicitHeight)
                if (tail >= 0) run.tail = tail
            }
        }
        if (run) out.push(run)
        return out
    }
    // The plate's outline: a circle round each cell, joined by necks that curve inward
    // (a metaball union, which a rounded box cannot draw). Each neck is an arc tangent
    // to both circles, solved from the triangle of the two radii and the neck radius.
    function fillet(a, b, R) {
        const d = b.x - a.x
        if (d <= 0) return null
        const ra = a.r + R, rb = b.r + R
        const ax = (ra * ra - rb * rb + d * d) / (2 * d)
        const h2 = ra * ra - ax * ax
        if (h2 <= 0.01) return null          // too far apart to be joined
        const h = Math.sqrt(h2)
        const fx = a.x + ax, fy = a.y - h    // the neck's centre, above the line
        const la = Math.hypot(fx - a.x, fy - a.y), lb = Math.hypot(fx - b.x, fy - b.y)
        return ({ R: R,
                  ax: a.x + a.r * (fx - a.x) / la, ay: a.y + a.r * (fy - a.y) / la,
                  bx: b.x + b.r * (fx - b.x) / lb, by: b.y + b.r * (fy - b.y) / lb })
    }
    function platePath(run) {
        const cs = (run.parts || []).map(p => ({ x: p.x + p.w / 2, y: p.y + p.h / 2,
                                                 r: Math.min(p.w, p.h) / 2 + run.pad }))
        if (cs.length === 0) return ""
        const necks = []
        for (let i = 0; i < cs.length - 1; ++i)
            necks.push(fillet(cs[i], cs[i + 1], run.neck > 0 ? run.neck
                                                             : Math.max(cs[i].r, cs[i + 1].r) * 1.5))
        const A = (r, x, y, sweep) => " A" + r.toFixed(2) + " " + r.toFixed(2) + " 0 0 " + sweep
                                    + " " + x.toFixed(2) + " " + y.toFixed(2)
        // How far the plate's bottom runs below the buttons; its top sits tangent to them.
        // Negative raises the bottom line into the buttons, which then stand proud of it.
        const drop = run.drop || 0
        const mirror = (c, y) => 2 * (c.y + drop) - y
        // The tail: the plate runs `tail` px past the last circle, its top level just
        // below that circle's crown, and the end sweeps down to the bottom line on a
        // convex quarter-ellipse twice as wide as the plate is deep.
        const tail = run.tail > 0 ? run.tail : 0
        const last = cs[cs.length - 1]
        const P = (x, y) => " " + x.toFixed(2) + " " + y.toFixed(2)
        let d = "M" + (cs[0].x - cs[0].r).toFixed(2) + " " + cs[0].y.toFixed(2)
        for (let i = 0; i < cs.length; ++i) {
            const n = necks[i]
            if (i < cs.length - 1 && n) {
                d += A(cs[i].r, n.ax, n.ay, 1) + A(n.R, n.bx, n.by, 0)
            } else if (i === cs.length - 1 && tail > 0) {
                const c = cs[i]
                const topY = c.y - c.r * 0.7                       // the level top, 0.3 r under the crown
                const ax = c.x + c.r * 0.7141, ay = topY           // where the circle meets it
                const tipX = c.x + c.r + tail
                const botY = c.y + drop + c.r                      // the plate's bottom line
                const ry = botY - topY, rx = Math.min(ry * 2, tipX - c.x)
                d += A(c.r, ax, ay, 1)
                d += " L" + P(tipX, topY)
                d += " A" + rx.toFixed(2) + " " + ry.toFixed(2) + " 0 0 1" + P(tipX - rx, botY)
                d += " L" + P(c.x, botY)
            } else {
                d += A(cs[i].r, cs[i].x + cs[i].r, cs[i].y, 1)
                if (i < cs.length - 1) {     // not joined: step across to the next
                    d += " L" + (cs[i + 1].x - cs[i + 1].r).toFixed(2) + " " + cs[i + 1].y.toFixed(2)
                }
            }
        }
        if (drop !== 0 && tail <= 0) d += " L" + (last.x + last.r).toFixed(2) + " " + (last.y + drop).toFixed(2)
        for (let i = cs.length - 1; i >= 0; --i) {
            const n = necks[i - 1]
            if (i > 0 && n) {
                d += A(cs[i].r, n.bx, mirror(cs[i], n.by), 1) + A(n.R, n.ax, mirror(cs[i - 1], n.ay), 0)
            } else {
                d += A(cs[i].r, cs[i].x - cs[i].r, (cs[i].y + drop), 1)
                if (i > 0) d += " L" + (cs[i - 1].x + cs[i - 1].r).toFixed(2) + " " + (cs[i - 1].y + drop).toFixed(2)
            }
        }
        return d + " Z"
    }
    Repeater {
        model: row.backings
        Shape {
            id: plate
            required property var modelData
            readonly property var roleR: Theme.role(modelData.role)
            readonly property var stops: (roleR && roleR.source === "gradient" && roleR.params
                                          && roleR.params.colours) ? roleR.params.colours : []
            readonly property color flat: roleR ? Qt.rgba(roleR.colour.r, roleR.colour.g, roleR.colour.b,
                                                          roleR.colour.a * roleR.opacity)
                                                : "transparent"
            z: -1
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillColor: plate.stops.length === 0 ? plate.flat : "white"
                fillGradient: plate.stops.length === 0 ? null : plateRamp
                PathSvg { path: row.platePath(plate.modelData) }
            }
            // Every stop the role has, where the role puts it: the plate this
            // copies is lit from below, which takes the whole ramp and its
            // places.
            readonly property var ramp: {
                const cols = [plate.flat].concat(plate.stops)
                const prm = plate.roleR && plate.roleR.params ? plate.roleR.params : ({})
                const n = plate.stops.length
                const out = []
                let was = 0
                for (let i = 0; i < cols.length; ++i) {
                    let at = 0
                    if (i > 0) {
                        const key = Number(prm["stop" + i])
                        at = Math.max(key > 0 ? key : i / n, was)
                    }
                    was = at
                    out.push({ at: at, c: cols[i] })
                }
                return out
            }
            function rampAt(i) { return ramp[Math.min(i, ramp.length - 1)] }
            LinearGradient {
                id: plateRamp
                x1: 0; y1: plate.modelData.y - plate.modelData.pad
                x2: 0; y2: plate.modelData.bottom + plate.modelData.pad
                GradientStop { position: plate.rampAt(0).at; color: plate.rampAt(0).c }
                GradientStop { position: plate.rampAt(1).at; color: plate.rampAt(1).c }
                GradientStop { position: plate.rampAt(2).at; color: plate.rampAt(2).c }
                GradientStop { position: plate.rampAt(3).at; color: plate.rampAt(3).c }
                GradientStop { position: plate.rampAt(4).at; color: plate.rampAt(4).c }
                GradientStop { position: plate.rampAt(5).at; color: plate.rampAt(5).c }
                GradientStop { position: plate.rampAt(6).at; color: plate.rampAt(6).c }
            }
        }
    }

    Repeater {
        id: rep
        model: cellsModel
        BarCell {
            ink: row.rowInk
            required property int index
            required property string docJson
            doc: JSON.parse(docJson)
            bar: row.bar
            layout: row.layout
            rowAnimating: row.animating
            placed: false
            onReadyChanged: row.checkReady()
            onShownChanged: { row.cellGen++; row.later() }
            onNaturalChanged: { row.cellGen++; row.later() }
            onImplicitHeightChanged: { row.cellGen++; row.later() }
            Component.onCompleted: { row.cellGen++; row.checkReady(); row.later() }
        }
    }
    // A width change lays out now: Qt.callLater lands after the frame renders, so each
    // resize frame would draw cells laid out for the previous width, a jitter worst
    // in the centre layout. layRun is 15us.
    onWidthChanged: relayout()
    // Height too: an "at: bottom" row lays its cell at `height - usedH`, so the edge
    // scrubber follows the height while the bar animates between layouts. A stacked
    // row moves with its own y instead.
    onHeightChanged: relayout()
    // A new document with the same cells keeps the row laid: the cells stay
    // and are laid out again. With other cells the row waits for them to be
    // ready, as at first — and checks now, since a cell already ready will
    // not say so again.
    onDocChanged: {
        syncModel()
        if ((doc.cells || []).length === 0) laid = true
        checkReady()
        later()
    }
    function later() { Qt.callLater(relayout) }

    function gapBefore(c) { return c.leaving ? 0 : (c.gap >= 0 ? c.gap : rowGap) }
    // at the edge of a run the row's gap does not apply, but a gap set on
    // the cell itself does: it insets the cell from the edge
    function edgeGap(c) { return c.leaving ? 0 : (c.gap >= 0 ? c.gap : 0) }
    // the space a cell asks for after itself, added to the next cell's own gap
    function gapAfterOf(c) { return c.leaving ? 0 : (c.gapAfter > 0 ? c.gapAfter : 0) }
    // lay a run of cells from x0 into avail, flex cells sharing the leftover
    function layRun(cells, x0, avail, noEdge) {
        let fixed = 0, flexSum = 0, gaps = 0
        cells.forEach((c, i) => { if (c.leaving) return; if (c.flex) flexSum += c.flexWeight; else fixed += c.natural
                                  gaps += (i > 0 ? gapBefore(c) : (noEdge ? 0 : edgeGap(c))) + gapAfterOf(c) })
        const leftover = Math.max(0, avail - fixed - gaps)
        // A flex cell with a maximum takes no more than it, and what it leaves
        // goes to the flex cells without one — shared again until none is over
        const share = new Map()
        let open = cells.filter(c => !c.leaving && c.flex), room = leftover
        while (open.length) {
            const sum = open.reduce((a, c) => a + c.flexWeight, 0)
            const over = open.filter(c => room * c.flexWeight / sum > c.maxW)
            if (!over.length) { open.forEach(c => share.set(c, room * c.flexWeight / sum)); break }
            over.forEach(c => { share.set(c, c.maxW); room -= c.maxW })
            open = open.filter(c => over.indexOf(c) < 0)
        }
        let x = x0
        cells.forEach((c, i) => {
            x += i > 0 ? gapBefore(c) : (noEdge ? 0 : edgeGap(c))
            // the width it is given, not read back: while a cell glides the
            // property holds the value on its way, and the run would stack up short
            const w = c.leaving ? 0 : c.flex ? share.get(c) : c.natural
            c.width = w
            c.x = x
            x += w + gapAfterOf(c)
        })
        return x - x0
    }
    function widthOf(cells, noEdge) {
        let w = 0
        cells.forEach((c, i) => { w += (c.flex ? 0 : c.natural) + gapAfterOf(c)
                                       + (i > 0 ? gapBefore(c) : (noEdge ? 0 : edgeGap(c))) })
        return w
    }
    function relayout() {
        // a row on its way out — the leaving layout's — can be asked to lay
        // out after its functions are gone
        if (typeof row.layRun !== "function") return
        Qt.callLater(function() { if (row && row.layout) row.layout.laidOut() })
        const W = width
        const cells = []
        for (let i = 0; i < rep.count; ++i) {
            const c = rep.itemAt(i); if (!c) return
            // a cell with nothing in it — an empty group, no plugins — takes no room and no gap
            // a cell on its way out stays in the run at a width of nothing
            // and no gap: it slides to the seam as it closes, and the cell
            // behind it glides up to that seam rather than over it
            if (c.shown && (c.leaving || c.flex || c.natural > 0)) cells.push(c); else c.width = 0
        }
        const top = onEdge ? height - usedH : 0
        cells.forEach(c => { c.y = top + padTop + (usedH - padTop - padBottom - c.implicitHeight) / 2 + (c.doc.dy || 0) })
        const ci = cells.findIndex(c => c.centre)
        if (ci < 0) { layRun(cells, 0, W); cells.forEach(c => c.placed = true); return }
        const centre = cells[ci]
        centre.width = centre.natural
        centre.x = (W - centre.width) / 2
        const left = cells.slice(0, ci), right = cells.slice(ci + 1)
        if (left.length) {
            const avail = centre.x - gapBefore(centre)
            if (left.some(c => c.flex)) layRun(left, 0, avail)
            else layRun(left, Math.max(0, avail - widthOf(left)), avail)
        }
        if (right.length) {
            // the first cell after the centre keeps its gap as the gap from
            // the centre, so the run starts past it with no edge inset
            const start = centre.x + centre.width + gapAfterOf(centre) + gapBefore(right[0])
            if (right.some(c => c.flex)) layRun(right, start, W - start, true)
            else layRun(right, Math.min(start, W - widthOf(right, true)), W - start, true)
        }
        // placed once laid out while shown: a cell's first placement is instant
        cells.forEach(c => c.placed = true)
        row.backGen++   // the plates follow the cells they sit under
    }
    onXChanged: if (layout) layout.laidOut()
    onYChanged: if (layout) layout.laidOut()
}
