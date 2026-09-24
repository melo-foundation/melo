import QtQuick
import ".."
import "barkeys.js" as Keys

// The arranger, laid over the live player bar: a handle per cell and per row,
// and a panel of slot, palette, picked cell's knobs, Add row and Done. It edits
// the rows in force at the window's width; a built-in forks on the first change.
Item {
    id: ed
    objectName: "barArrange"
    property Item bar                            // the live PlayerBar, which this fills
    readonly property string slot: Theme.arrangeSlot
    readonly property string id: String(ThemeBackend.settings[slot] || (slot === "barNp" ? "centre" : "rows"))
    readonly property bool builtIn: ThemeBackend.isBuiltInLayout(id)
    // the slot's document: its unsaved edits if it has any, else the layout
    readonly property var doc: Theme.slotDoc(slot + ":" + id, slot === "barMini")
    readonly property bool custom: { const dep = Theme.layoutGen; return ThemeBackend.hasLayoutOverride(slot) }
    readonly property string layoutName: (doc.name || id) + (custom ? " · Custom" : "")
    readonly property bool narrow: bar ? bar.narrowVariant : false
    readonly property var rows: bar ? bar.shownRows : []

    // The elements: each its own entry, a plugin's buttons among melo's
    readonly property var buttonLabels: ({ library: "Add to library", radio: "Radio", eq: "EQ", queue: "Queue", vis: "Visualizer" })
    readonly property var elements: {
        const dep = typeof BarButtons !== "undefined" && BarButtons ? BarButtons.generation : 0
        const l = [ { type: "thumb", label: "Thumb" }, { type: "title", artist: "none", label: "Title" },
                    { type: "title", label: "Title + artist" }, { type: "artist", label: "Artist" },
                    { type: "prev", label: "Previous" }, { type: "play", label: "Play" }, { type: "playdisc", label: "Play disc" },
                    { type: "next", label: "Next" }, { type: "scrub", label: "Scrub" },
                    { type: "elapsed", label: "Elapsed" }, { type: "total", label: "Total" }, { type: "countdown", label: "Countdown" },
                    { type: "time", label: "Time" } ]
        for (const id of Theme.buttonIds) l.push({ type: "button", id: id, label: buttonLabels[id] })
        if (typeof BarButtons !== "undefined" && BarButtons)
            for (const b of BarButtons.all()) if (b.bar === "player")
                l.push({ type: "button", id: "plugin:" + b.pluginId + "." + b.id, label: b.label })
        l.push({ type: "volume", label: "Volume" }); l.push({ type: "spacer", label: "Spacer" })
        return l
    }
    function keyOf(c) { return Keys.elementKey(c) }
    // Where an element sits in the rows, the first of it, or null. Only for
    // the click that picks it: nothing stops a second copy being dragged on.
    function find(e) {
        const key = Keys.elementKey(e.type === "button" ? { type: "button", id: e.id } : e)
        for (let r = 0; r < rows.length; ++r) for (let c = 0; c < (rows[r].cells || []).length; ++c) if (Keys.elementKey(rows[r].cells[c]) === key) return { r: r, c: c }
        return null
    }
    function placed(e) { return find(e) !== null }
    function labelOf(c) {
        if (c.type === "button") { for (const e of elements) if (e.type === "button" && e.id === c.id) return e.label; return c.id }
        for (const e of elements) if (Keys.elementKey(e) === Keys.elementKey(c)) return e.label
        return c.type
    }

    // WRITE: the slot's unsaved override. Nothing is saved to the list until
    // Save or Save as; Discard drops the edits. The rows written are the
    // rows in force: the variant's under a narrow window.
    function commit(next) { ThemeBackend.setLayoutOverride(slot, JSON.parse(JSON.stringify(next))) }
    // the layout's own controls
    function pickLayout(lid) { ThemeBackend.clearLayoutOverride(slot); ThemeBackend.setThemeSetting(slot, lid); picked = "" }
    function saveOver() { if (!custom || builtIn) return; ThemeBackend.setLayoutDoc(id, doc); ThemeBackend.clearLayoutOverride(slot) }
    function saveAs(name) {
        if (!name) return
        const nid = ThemeBackend.saveLayoutDoc(doc, name)
        ThemeBackend.clearLayoutOverride(slot)
        ThemeBackend.setThemeSetting(slot, nid)
    }
    function discard() { ThemeBackend.clearLayoutOverride(slot); picked = "" }
    function deleteLayout() { if (builtIn) return; const old = id; pickLayout("rows"); ThemeBackend.deletePreset("layout", old) }
    readonly property var layoutList: { const dep = Theme.layoutGen; return ThemeBackend.presets("layout") }
    function withDoc(fn) { const d = JSON.parse(JSON.stringify(doc)); fn(d, narrow && d.variants && d.variants[0] ? d.variants[0] : d); commit(d) }
    function withRows(fn) { withDoc((d, v) => fn(v.rows)) }

    // Where the cells are, in the bar's space, read once the swap has settled
    property var rects: ({})
    property var rowRects: []
    function refresh() {
        if (!bar) return
        const m = {}; const rr = []
        for (let r = 0; r < rows.length; ++r) {
            rr.push(bar.rowRect(r, bar))
            for (let c = 0; c < (rows[r].cells || []).length; ++c) {
                const x = bar.cellRect(r, c, bar); if (x && x.width > 0) m[r + "," + c] = x
            }
        }
        rects = m; rowRects = rr
    }
    Timer { id: settle; interval: 450; onTriggered: ed.refresh() }
    // How far the handles are from their cells, for the test hooks: the
    // snapshot above against where the cells actually are now. Anything but
    // zero is a press that will land on the wrong cell.
    function handleDrift() {
        // meaningless mid-drag: the handles are frozen and hidden then, and the
        // ghost is what says where the cell will land
        if (dragCell !== null) return "dragging"
        let worst = 0, worstKey = "", n = 0, out = []
        for (let r = 0; r < rows.length; ++r)
            for (let c = 0; c < (rows[r].cells || []).length; ++c) {
                const live = bar ? bar.cellRect(r, c, bar) : null
                const snap = rects[r + "," + c]
                if (!live || !snap || live.width <= 0) continue
                ++n
                const d = Math.max(Math.abs(live.x - snap.x), Math.abs(live.width - snap.width))
                if (d > 0.5) out.push(r + "," + c + " off by " + d.toFixed(1))
                if (d > worst) { worst = d; worstKey = r + "," + c }
            }
        return "cells=" + n + " worst=" + worst.toFixed(1) + (worstKey.length ? " at " + worstKey : "")
             + (out.length ? " [" + out.join("; ") + "]" : "")
    }
    // and the moment the bar has laid out, so a just-dropped element has its
    // handle at once
    Connections { target: ed.bar; function onLaidOut() { if (ed.visible) ed.refresh() } }
    // `laidOut` fires when a row starts laying out and the cells then glide, so a
    // snapshot taken there is up to 15 px off for ~600 ms and a press lands on the
    // neighbour. mapToItem is not reactive, so cells are re-read once per frame
    // while the arranger is on screen.
    Connections {
        target: ed.visible ? ed.Window.window : null
        function onAfterAnimating() { ed.refresh() }
    }
    onRowsChanged: { settle.restart(); if (Keys.isCell(picked) && !pickedCell) picked = ""
                     if (dragCell === null) rebuildHandles() }
    onWidthChanged: settle.restart()
    onVisibleChanged: if (visible) settle.restart()
    Component.onCompleted: { settle.restart(); rebuildHandles() }

    // What is picked, by identity: a cell's key within its row, not its place
    // in it, so the selection follows the cell through reorders and edits to
    // the row's makeup. Rows keep their index: they have no identity
    // of their own and nothing drags them.
    property string picked: ""
    readonly property int pickedRow: Keys.pickRow(picked)
    // the index in the row of the picked cell, or -1 — resolved on every read,
    // so a row that has changed under the selection answers with where the
    // cell is now rather than where it was
    readonly property int pickedIndex: {
        const dep = rows
        if (!Keys.isCell(picked) || pickedRow < 0 || !rows[pickedRow]) return -1
        return Keys.indexOfKey(rows[pickedRow].cells || [], Keys.pickKey(picked))
    }
    readonly property var pickedCell: {
        const i = pickedIndex
        return i < 0 ? null : rows[pickedRow].cells[i]
    }

    function rowAt(by) {
        for (let r = 0; r < rowRects.length; ++r) { const rr = rowRects[r]; if (rr && by >= rr.y && by <= rr.y + rr.height) return r }
        return -1
    }
    // The drag, live. While one is in flight the bar draws a preview: the
    // cell taken from where it was and put where the pointer would drop it,
    // faint, and the others glide aside — the queue's feel. The drop commits
    // what is already on screen; a drop below the bar commits without it.
    property var previewDoc: null
    property var dragCell: null          // the cell in flight
    property var dragFrom: null          // {r, c} it came from, or null from the shelf
    property var dragAt: null            // {r, i} it is previewed at, or null (out)
    function beginDrag(from, entry) {
        dragFrom = from
        dragCell = from ? JSON.parse(JSON.stringify(rows[from.r].cells[from.c])) : defaultCell(entry)
        dragAt = null
        takeDropEdges(from)      // before the preview moves anything
        previewWith(null)
    }
    // the preview document with the cell at (r, i), or out
    function previewWith(at) {
        const d = JSON.parse(JSON.stringify(doc))
        const v = narrow && d.variants && d.variants[0] ? d.variants[0] : d
        if (dragFrom) dropFrom(v.rows[dragFrom.r].cells, dragFrom.c)
        if (at) { const c = JSON.parse(JSON.stringify(dragCell)); c._drag = true; v.rows[at.r].cells.splice(at.i, 0, c) }
        previewDoc = d
    }
    // Drop boundaries are taken once when the drag begins, from the row without the
    // dragged cell: the preview sets live cells gliding, so their midpoints move
    // under a still pointer and the drop index would flicker.
    property var dropEdges: []          // per row, the midpoints to cross
    function takeDropEdges(from) {
        const e = []
        for (let r = 0; r < rows.length; ++r) {
            const mids = []
            const cells = rows[r].cells || []
            for (let c = 0; c < cells.length; ++c) {
                if (from && from.r === r && from.c === c) continue
                const rc = bar ? bar.cellRect(r, c, bar) : null
                if (rc && rc.width > 0) mids.push(rc.x + rc.width / 2)
            }
            e.push(mids)
        }
        dropEdges = e
    }
    function previewIndex(r, bx) {
        const mids = dropEdges[r] || []
        let i = 0
        for (let m = 0; m < mids.length; ++m) if (bx > mids[m]) i++
        return i
    }
    function moveDrag(bx, by) {
        if (!dragCell || !previewDoc) return
        let r = -1
        for (let i = 0; i < rows.length; ++i) { const rr = bar.rowRect(i, bar); if (rr && by >= rr.y - 6 && by <= rr.y + rr.height + 6) { r = i; break } }
        const at = r < 0 ? null : { r: r, i: previewIndex(r, bx) }
        const same = (at === null && dragAt === null) || (at && dragAt && at.r === dragAt.r && at.i === dragAt.i)
        if (same) return
        dragAt = at
        previewWith(at)
    }
    function endDrag() {
        if (!dragCell) return
        const d = JSON.parse(JSON.stringify(previewDoc))
        const strip = (rows) => { for (const r of rows || []) for (const c of r.cells || []) delete c._drag }
        strip(d.rows); for (const v of d.variants || []) strip(v.rows)
        // committed before the preview goes: with the preview gone first the
        // bar reads the old document for a moment, drops the new cell, and
        // builds it again when the commit lands
        commit(d)
        dragCell = null; dragFrom = null; dragAt = null; previewDoc = null; dropEdges = []
        picked = ""
    }
    function cancelDrag() { dragCell = null; dragFrom = null; dragAt = null; previewDoc = null; dropEdges = [] }
    // the scripted drop, for the shot hook: one move and the drop
    function drop(from, entry, bx, by) { beginDrag(from, entry); moveDrag(bx, by); endDrag() }
    // the element as the shelf shows it: its default, at a width that fits
    function shelfCell(entry) {
        const c = defaultCell(entry)
        if (c.type === "title") { c.flex = undefined; c.lines = 1; c.artist = c.artist === "none" ? "none" : "inline" }
        if (c.type === "scrub") { c.flex = undefined; c.w = 90 }
        if (c.type === "spacer") c.w = 24
        if (c.type === "volume") c.w = 70
        return c
    }
    function defaultCell(entry) {
        const e = typeof entry === "string" ? { type: entry } : entry
        switch (e.type) {
        case "thumb": return { type: "thumb", w: 48, h: 28 }
        case "title": return e.artist === "none" ? { type: "title", flex: 1, lines: 1, artist: "none" }
                                                 : { type: "title", flex: 1, lines: 2, artist: "below" }
        case "prev": case "play": case "playdisc": case "next": return { type: e.type, size: 24 }
        case "scrub": return { type: "scrub", flex: 1, h: 24 }
        case "button": return { type: "button", id: e.id }
        case "spacer": return { type: "spacer", w: 16 }
        case "volume": return { type: "volume", w: 90 }
        }
        return { type: e.type }
    }
    // The palette roles a cell may name: the ones melo knows plus any the
    // theme invented, because a plate or a face may be a role of the theme's
    // own making and a fixed list cannot reach it.
    function roleList() {
        const seen = {}, out = []
        const add = (r) => { if (r && seen[r] === undefined) { seen[r] = 1; out.push(r) } }
        Theme.surfaceRoles.forEach(add)
        Object.keys(Theme.p || {}).forEach(k => { if (Theme.inkRoles.indexOf(k) < 0) add(k) })
        return out
    }
    function setKnob(key, value) {
        if (!picked) return
        if (Keys.isRow(picked)) {
            const r = pickedRow
            withDoc((d, v) => {
                if (key === "height") v.height = (v.height || d.height || 77) + (value - (v.rows[r].height || 24))
                // a row key set back to nothing follows the document again
                if (value === undefined) delete v.rows[r][key]; else v.rows[r][key] = value
            })
            return
        }
        const r = pickedRow, c = pickedIndex
        if (r < 0 || c < 0) return
        // The knob moves the selection with it. A cell's identity is its kind,
        // and a spacer's kind is its width — so widening a spacer renames it,
        // and the pick has to be renamed too or the next turn of the knob
        // addresses nothing.
        withRows(rs => {
            const cell = rs[r].cells[c]
            if (value === undefined) delete cell[key]; else cell[key] = value
            if (key === "centre" && value === true) rs[r].cells.forEach((o, i) => { if (i !== c) delete o.centre })
            picked = Keys.cellPick(r, Keys.cellKeys(rs[r].cells)[c])
        })
    }
    // Take a cell out of a row, and hand the centre on if it held it: a row
    // whose centred cell is gone has no centre, and every cell in it jumps to
    // one end.
    function dropFrom(cells, i) {
        const was = cells[i] && cells[i].centre === true
        cells.splice(i, 1)
        if (was && cells.length) cells[Math.min(i, cells.length - 1)].centre = true
    }
    function removeCell(r, c) { withRows(rs => dropFrom(rs[r].cells, c)); picked = "" }
    // pick by place, for a caller that has indices and not identities — the
    // test hooks, and anything that has just built a row
    function pickCell(r, c) {
        const cells = rows[r] ? (rows[r].cells || []) : []
        picked = c >= 0 && c < cells.length ? Keys.cellPick(r, Keys.cellKeys(cells)[c]) : ""
    }
    function removePicked() { if (pickedIndex >= 0) removeCell(pickedRow, pickedIndex) }
    // one row's height, by index — the panel sets every row's without one
    // having to be picked first. Same rule as the knob and the seam: the bar's
    // own height moves with it, because the bar states its height rather than
    // adding up its rows.
    function setRowHeight(r, h) {
        withDoc((d, v) => {
            if (!v.rows[r]) return
            v.height = (v.height || d.height || 77) + (h - (v.rows[r].height || 24))
            v.rows[r].height = h
        })
    }
    function addRow() {
        withDoc((d, v) => { v.rows.push({ height: 24, gap: 8, cells: [] }); v.height = (v.height || d.height || 77) + 24 + (d.rowGap || 4) })
    }
    function removeRow(r) {
        withDoc((d, v) => { const h = v.rows[r].height || 24; v.rows.splice(r, 1); v.height = Math.max(24, (v.height || d.height || 77) - h - (d.rowGap || 4)) })
        picked = ""
    }

    DropMenu { id: layoutMenu }
    DropMenu { id: roleMenu }
    Connections {
        target: Portal
        function onPicked(tag, paths) {
            if (tag === "layout-export" && paths.length) ThemeBackend.exportLayoutDoc(ed.doc, paths[0])
            else if (tag === "layout-import" && paths.length) { const lid = ThemeBackend.importPreset(paths[0]); if (lid) ed.pickLayout(lid) }
        }
    }
    // ---- the element in flight, under the pointer: the shelf's card of it,
    // lifted, since the bare element is lost against the bar
    Surface {
        id: ghost
        objectName: "ghost"
        visible: ed.dragCell !== null
        z: 30
        width: Math.max(Theme.ctl(44), ghostCell.width + 16, ghostLabel.implicitWidth + 16)
        height: ghostCell.height + ghostLabel.implicitHeight + Theme.gap(10)
        radius: Theme.radiusMd
        role: "dialog"
        borderRole: "borderStrong"; borderWidth: 1
        scale: 1.06
        BarCell {
            id: ghostCell
            doc: ed.dragCell ? ed.shelfCell(ed.dragCell) : ({})
            bar: ed.bar
            anchors.horizontalCenter: parent.horizontalCenter
            y: Theme.gap(4)
            width: Math.max(8, Math.min(natural || 0, 140)); height: implicitHeight
            enabled: false
        }
        InkText { id: ghostLabel; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.gap(3)
                  text: ed.dragCell ? ed.labelOf(ed.dragCell) : ""; ink: "textDim"
                  font { pixelSize: Theme.fs(9); family: Theme.fontFamily } }
    }
    component Handle: MouseArea {
        property var from: null
        property var entry: null
        property string pick: ""
        hoverEnabled: true
        cursorShape: Qt.OpenHandCursor
        property bool dragging: false
        property real px: 0
        property real py: 0
        onPressed: (m) => { dragging = false; px = m.x; py = m.y
                            if (MELO_ARRANGE_DEBUG) console.warn("[arrange] press pick=" + pick + " from=" + JSON.stringify(from)) }
        // a press that moves a little is a click: the drag starts past a
        // threshold, so picking a cell does not turn into a drop of it
        onPositionChanged: (m) => {
            if (!pressed) return
            if (!dragging) {
                if (Math.abs(m.x - px) + Math.abs(m.y - py) < 6) return
                dragging = true
                if (MELO_ARRANGE_DEBUG) console.warn("[arrange] threshold -> beginDrag")
                ed.beginDrag(from, entry)
                if (MELO_ARRANGE_DEBUG) console.warn("[arrange] after beginDrag dragCell=" + (ed.dragCell !== null) + " visible=" + visible + " pressed=" + pressed)
            }
            const p = mapToItem(ed, m.x, m.y)
            ghost.x = p.x - ghost.width / 2; ghost.y = p.y - ghost.height / 2
            ed.moveDrag(p.x, p.y)
        }
        onReleased: (m) => {
            if (MELO_ARRANGE_DEBUG) console.warn("[arrange] released dragging=" + dragging)
            if (!dragging) { if (pick.length) ed.picked = ed.picked === pick ? "" : pick; return }
            dragging = false
            ed.endDrag()
        }
        onCanceled: { if (MELO_ARRANGE_DEBUG) console.warn("[arrange] CANCELED (grab lost) dragging=" + dragging)
                      dragging = false; ed.cancelDrag() }
    }
    // ---- nothing reaches the bar: a press or a wheel between the handles
    // ends here, not on a scrub or a volume slider
    MouseArea {
        anchors.fill: parent
        z: 15
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: (w) => w.accepted = true
    }
    // ---- row heights, dragged on the seam under each row (the gap, no cell).
    // Previewed live, committed on release: writing the document per frame would put
    // a settings write, themesChanged and a full re-read on each one.
    property real rowDragH: 0
    function previewRowHeight(r, h) {
        const d = JSON.parse(JSON.stringify(doc))
        const v = narrow && d.variants && d.variants[0] ? d.variants[0] : d
        if (!v.rows[r]) return
        v.height = (v.height || d.height || 77) + (h - (v.rows[r].height || 24))
        v.rows[r].height = h
        previewDoc = d
    }
    Repeater {
        model: ed.rows.length
        Item {
            required property int index
            readonly property var rr: ed.rowRects[index]
            // an edge row is the bar's whole height; there is no seam to pull
            readonly property bool draggable: rr !== undefined && rr !== null
                                              && ed.rows[index] && ed.rows[index].at !== "bottom"
            visible: draggable && ed.dragCell === null
            x: 0
            y: rr ? rr.y + rr.height - Theme.sp(3) : 0
            width: ed.width
            height: Theme.sp(7)
            z: 22
            Surface {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: Math.max(1, Theme.sp(rowMa.containsMouse || rowMa.pressed ? 3 : 1))
                radius: height / 2
                role: rowMa.pressed ? "selected" : rowMa.containsMouse ? "highlight" : "border"
                opacity: rowMa.containsMouse || rowMa.pressed ? 1 : 0.35
                Behavior on height { NumberAnimation { duration: Theme.motionFast; easing.type: Theme.motionEase } }
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeVerCursor
                // Measured in the window: the bar is anchored to the window's bottom, so a row
                // that grows moves this item's origin up, and a delta taken here would feed on
                // itself. The window does not move during this drag.
                property real originY: 0
                onPressed: (m) => {
                    ed.picked = Keys.rowPick(parent.index)
                    originY = mapToItem(null, m.x, m.y).y
                    ed.rowDragH = ed.rows[parent.index] ? (ed.rows[parent.index].height || 24) : 24
                }
                onPositionChanged: (m) => {
                    if (!pressed) return
                    const dy = mapToItem(null, m.x, m.y).y - originY
                    ed.previewRowHeight(parent.index, Math.max(16, Math.min(64, Math.round(ed.rowDragH + dy))))
                }
                onReleased: {
                    if (ed.previewDoc) { const d = ed.previewDoc; ed.previewDoc = null; ed.commit(d) }
                }
                onCanceled: ed.previewDoc = null
            }
        }
    }
    // ---- handles over the cells, in the bar's own space (this fills the bar)
    // Frozen while a drag is in flight, rebuilt when it ends: any change to this
    // JS-array model rebuilds every delegate, including the one holding the mouse
    // grab, and the preview rewrites the rows on every pointer move.
    property var handleModel: []
    function rebuildHandles() {
        const l = []
        for (let r = 0; r < rows.length; ++r) for (let c = 0; c < (rows[r].cells || []).length; ++c) l.push({ r: r, c: c })
        // Only when the shape changed. Reassigning rebuilds every delegate, and
        // a row being resized writes a document a frame — same rows, same
        // cells, a different height — which would churn the whole set of
        // handles through a drag that moves none of them.
        if (l.length === handleModel.length
            && l.every((e, i) => e.r === handleModel[i].r && e.c === handleModel[i].c)) return
        handleModel = l
    }
    onDragCellChanged: if (dragCell === null) rebuildHandles()
    Repeater {
        model: ed.handleModel
        Item {
            required property var modelData
            // WHERE it is, for the rectangle; WHAT it is, for the selection.
            readonly property string key: modelData.r + "," + modelData.c
            readonly property string pick: Keys.cellPick(modelData.r,
                Keys.cellKeys(ed.rows[modelData.r].cells || [])[modelData.c] || "")
            readonly property var rc: ed.rects[key]
            readonly property var cell: ed.rows[modelData.r].cells[modelData.c]
            // Alive while dragging, even with nothing to draw. Hiding a
            // MouseArea takes its grab away and Qt cancels the drag through
            // it, re-entrantly inside the beginDrag that set `dragCell`. Only
            // the frame is hidden.
            visible: rc !== undefined || ed.dragCell !== null
            x: rc ? rc.x - 2 : 0
            y: rc ? rc.y - 2 : 0
            width: rc ? Math.max(8, rc.width) + 4 : 0
            height: rc ? rc.height + 4 : 0
            z: 20
            Surface {
                anchors.fill: parent
                radius: Theme.radiusSm
                // a frame only under the pointer, or on the picked one; the bar
                // is itself while nothing is happening to it, and while
                // something is, the ghost is what says where the cell will land
                visible: ed.dragCell === null
                // the fill alone says which one the pointer is on: an outline
                // around every cell would draw a grid over the bar
                role: ed.picked === parent.pick ? "selected" : (hMa.containsMouse ? "hover" : "")
                opacity: ed.picked === parent.pick ? 0.35 : (hMa.containsMouse ? 0.5 : 1)
            }
            Handle { id: hMa; anchors.fill: parent; from: parent.modelData; pick: parent.pick }
        }
    }
    // ---- the panel, above the bar
    Surface {
        id: panel
        z: 25
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.top
        anchors.bottomMargin: Theme.gap(6)
        anchors.leftMargin: Theme.gap(10)
        anchors.rightMargin: Theme.gap(10)
        height: panelCol.implicitHeight + Theme.gap(20)
        radius: Theme.radiusLg
        role: "dialog"
        borderRole: "border"; borderWidth: 1
        // A press, a hover or a wheel on the panel's own ground ends here, so
        // nothing under the panel is clicked. Nothing outside the panel is
        // covered, so the now-playing page still swipes around it.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: (w) => w.accepted = true
        }
        Column {
            id: panelCol
            x: Theme.gap(12); y: Theme.gap(10)
            width: parent.width - Theme.gap(24)
            spacing: Theme.gap(8)
            // The slot, the layout and its buttons wrap, so none run off the
            // panel as the window narrows.
            Flow {
                width: parent.width
                spacing: Theme.gap(8)
                Row {
                    spacing: Theme.gap(2)
                    Repeater {
                        model: [ { v: "barMain", l: "Main" }, { v: "barNp", l: "Now playing" }, { v: "barMini", l: "Mini player" } ]
                        SelectTab {
                            required property var modelData
                            style: Theme.chips
                            label: modelData.l
                            active: Theme.arrangeSlot === modelData.v
                            hover: sMa.containsMouse; pressed: sMa.pressed
                            fontSize: 11
                            width: implicitWidth; height: Theme.ctl(22)
                            MouseArea { id: sMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: { Theme.arrangeSlot = parent.modelData.v; ed.picked = "" } }
                        }
                    }
                }
                // the layout: pick another, save, save as, discard, rename, delete, export, import
                SelectHead {   // the layout picker
                    id: lpMa
                    label: ed.layoutName + (ed.narrow ? "  ·  narrow" : "")
                    menu: layoutMenu
                    onClicked: {
                        const p = lpMa.mapToItem(null, 0, lpMa.height + 2)
                        layoutMenu.openAt(ed.Window.window, p.x, p.y,
                            ed.layoutList.map(l => ({ label: l.name, act: () => ed.pickLayout(l.id) })), lpMa)
                    }
                }
                PushButton { visible: ed.custom && !ed.builtIn; label: "Save"; accent: true; onClicked: ed.saveOver() }
                PushButton { visible: ed.custom; label: "Save as"; accent: ed.builtIn
                       onClicked: promptDialog.promptDialog("Layout name", (ed.doc.name || ed.id) + " Custom", (n) => ed.saveAs(n)) }
                PushButton { visible: ed.custom; label: "Discard"; onClicked: ed.discard() }
                PushButton { visible: !ed.custom && !ed.builtIn; label: "Rename"
                       onClicked: promptDialog.promptDialog("Layout name", ed.doc.name || "", (n) => { if (n) ThemeBackend.renamePreset("layout", ed.id, n) }) }
                PushButton { visible: !ed.custom && !ed.builtIn; label: "Delete"; onClicked: ed.deleteLayout() }
                PushButton { label: "Export"; onClicked: Portal.saveFile("layout-export", "Export layout", (ed.doc.name || "layout") + ".json", "Layout", ["*.json"]) }
                PushButton { label: "Import"; onClicked: Portal.openFile("layout-import", "Import layout", "Layout", ["*.json"], false) }
                // Every row's height, one per row, without picking the row
                // first. The name still picks the row, for its other knobs.
                Column {
                    spacing: Theme.gap(2)
                    Repeater {
                        model: ed.rows.length
                        Row {
                            required property int index
                            spacing: Theme.gap(8)
                            SelectTab {
                                style: Theme.chips
                                label: "Row " + (parent.index + 1)
                                active: ed.picked === Keys.rowPick(parent.index)
                                hover: rMa.containsMouse; pressed: rMa.pressed
                                fontSize: 11
                                width: implicitWidth; height: Theme.ctl(22)
                                anchors.verticalCenter: parent.verticalCenter
                                MouseArea { id: rMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: ed.picked = ed.picked === Keys.rowPick(parent.parent.index)
                                                                 ? "" : Keys.rowPick(parent.parent.index) }
                            }
                            MSlider {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.sp(140)
                                from: 16; to: 64; step: 1
                                value: ed.rows[parent.index] ? (ed.rows[parent.index].height || 24) : 24
                                onCommitted: (v) => ed.setRowHeight(parent.index, Math.round(v))
                            }
                            InkText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.sp(22)
                                horizontalAlignment: Text.AlignRight
                                text: ed.rows[parent.index] ? (ed.rows[parent.index].height || 24) : 24
                                ink: "textSoft"
                                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                            }
                        }
                    }
                }
            }
            // The shelf: the elements themselves, drawn by the cells the bar
            // uses, each with its name under it; a placed one is faint
            Flow {
                width: parent.width
                spacing: Theme.gap(6)
                Repeater {
                    model: ed.elements
                    Item {
                        required property var modelData
                        readonly property bool placed: ed.placed(modelData)
                        width: Math.max(Theme.ctl(44), shelfCell.width + 12, sLabel.implicitWidth + 12)
                        height: shelfCell.height + sLabel.implicitHeight + Theme.gap(10)
                        // faint only while it is the one in flight: an element
                        // may be placed as many times as it is dragged
                        opacity: ed.dragCell && ed.dragFrom === null && ed.keyOf(ed.dragCell) === ed.keyOf(ed.defaultCell(modelData)) ? 0.35 : 1
                        // no outline here either: the card's own ground is
                        // what separates one element from the next
                        Surface { anchors.fill: parent; radius: Theme.radiusMd
                                  role: ed.picked.length && ed.picked === sMa.pick ? "selected" : sMa.containsMouse ? "hover" : "button" }
                        BarCell {
                            id: shelfCell
                            doc: ed.shelfCell(parent.modelData)
                            bar: ed.bar
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: Theme.gap(4)
                            width: Math.max(8, Math.min(natural || 0, 140)); height: implicitHeight
                            enabled: false
                        }
                        InkText { id: sLabel; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.gap(3)
                                  text: parent.modelData.label; ink: "textDim"
                                  font { pixelSize: Theme.fs(9); family: Theme.fontFamily } }
                        // A drag adds another, always: a second spacer, a
                        // second button. A click on an element already on the
                        // bar picks that one, which is the only way to reach a
                        // cell the window is too narrow to show.
                        Handle { id: sMa; anchors.fill: parent; entry: parent.modelData
                                 pick: parent.placed ? (function() {
                                     const f = ed.find(parent.modelData); if (!f) return ""
                                     return Keys.cellPick(f.r, Keys.cellKeys(ed.rows[f.r].cells || [])[f.c] || "")
                                 })() : "" }
                    }
                }
            }
            // the knobs of what is picked
            Column {
                id: knobs
                width: parent.width
                visible: ed.picked.length > 0
                spacing: Theme.gap(2)
                readonly property var cell: ed.pickedCell
                readonly property bool isRow: Keys.isRow(ed.picked)
                readonly property var row: isRow ? ed.rows[ed.pickedRow] : null
                readonly property string type: cell ? cell.type : ""
                // the plate's own knobs only once a cell is on a plate
                readonly property bool plate: cell !== null && cell !== undefined && cell.backing !== undefined
                readonly property var onOff: [ { v: true, l: "On" }, { v: false, l: "Off" } ]
                component Knob: Item {
                    property string name
                    default property alias content: slot.data
                    width: knobs.width; height: Theme.ctl(28)
                    InkText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: parent.name; ink: "textSoft"
                              font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                    Item { id: slot; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: childrenRect.width; height: parent.height }
                }
                component Choice: Row {
                    property string key
                    property var options: []
                    property var current
                    property var map: (v) => v
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(2)
                    Repeater {
                        model: parent.options
                        SelectTab {
                            required property var modelData
                            style: Theme.chips
                            label: modelData.l
                            active: parent.current === modelData.v
                            hover: cMa.containsMouse; pressed: cMa.pressed
                            fontSize: 11
                            width: implicitWidth; height: Theme.ctl(22)
                            MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: ed.setKnob(parent.parent.key, parent.parent.map(parent.modelData.v)) }
                        }
                    }
                }
                component Num: MSlider {
                    property string key
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.sp(160)
                    onCommitted: (v) => ed.setKnob(key, Math.round(v))
                }
                // a palette role, off a dropdown: the list is long and a theme
                // may have added to it, so it is not a row of chips
                component Role: SelectHead {
                    id: rh
                    property string key
                    property string current: ""
                    property string none: "None"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.sp(160)
                    label: rh.current.length ? rh.current : rh.none
                    menu: roleMenu
                    onClicked: {
                        const p = rh.mapToItem(null, 0, rh.height + 2)
                        roleMenu.openAt(ed.Window.window, p.x, p.y,
                            [ { label: rh.none, act: () => ed.setKnob(rh.key, undefined), rule: true } ]
                                .concat(ed.roleList().map(r => ({ label: r, act: () => ed.setKnob(rh.key, r) }))), rh)
                    }
                }
                Knob {
                    name: knobs.isRow ? "Row " + (ed.pickedRow + 1) : (knobs.cell ? ed.labelOf(knobs.cell) : "")
                    PushButton {
                        label: "Remove"; ink: "danger"
                        onClicked: {
                            if (knobs.isRow) ed.removeRow(ed.pickedRow)
                            else ed.removePicked()
                        }
                    }
                }
                Knob { visible: knobs.isRow; name: "Height"
                       Num { key: "height"; from: 16; to: 64; step: 1; value: knobs.row ? (knobs.row.height || 24) : 24 } }
                Knob { visible: knobs.isRow; name: "Gap"
                       Num { key: "gap"; from: 0; to: 32; step: 1; value: knobs.row ? (knobs.row.gap !== undefined ? knobs.row.gap : 8) : 8 } }
                // -1 is "the document's"; the slider's own low end
                Knob { visible: knobs.isRow; name: "Pad left"
                       Num { key: "padLeft"; from: -1; to: 64; step: 1
                             value: knobs.row && knobs.row.padLeft !== undefined ? knobs.row.padLeft : -1
                             onCommitted: (v) => ed.setKnob("padLeft", Math.round(v) < 0 ? undefined : Math.round(v)) } }
                Knob { visible: knobs.isRow; name: "Pad right"
                       Num { key: "padRight"; from: -1; to: 64; step: 1
                             value: knobs.row && knobs.row.padRight !== undefined ? knobs.row.padRight : -1
                             onCommitted: (v) => ed.setKnob("padRight", Math.round(v) < 0 ? undefined : Math.round(v)) } }
                Knob { visible: knobs.isRow; name: "Pad top"
                       Num { key: "padTop"; from: 0; to: 32; step: 1; value: knobs.row ? (knobs.row.padTop || 0) : 0
                             onCommitted: (v) => ed.setKnob("padTop", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: knobs.isRow; name: "Pad bottom"
                       Num { key: "padBottom"; from: 0; to: 32; step: 1; value: knobs.row ? (knobs.row.padBottom || 0) : 0
                             onCommitted: (v) => ed.setKnob("padBottom", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: !knobs.isRow; name: "Width"
                       Choice { key: "flex"; current: knobs.cell ? (knobs.cell.flex || 0) : 0
                                options: [ { v: 0, l: "Own" }, { v: 1, l: "Flex" }, { v: 2, l: "Flex ×2" } ]
                                map: (v) => v === 0 ? undefined : v } }
                Knob { visible: !knobs.isRow; name: "Centre"
                       Choice { key: "centre"; current: knobs.cell ? knobs.cell.centre === true : false; options: knobs.onOff
                                map: (v) => v ? true : undefined } }
                Knob { visible: !knobs.isRow; name: "Gap before"
                       Num { key: "gap"; from: 0; to: 40; step: 1; value: knobs.cell ? (knobs.cell.gap !== undefined ? knobs.cell.gap : 8) : 8 } }
                Knob { visible: !knobs.isRow; name: "Gap after"
                       Num { key: "gapAfter"; from: 0; to: 40; step: 1; value: knobs.cell ? (knobs.cell.gapAfter || 0) : 0
                             onCommitted: (v) => ed.setKnob("gapAfter", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: !knobs.isRow; name: "Hide under"
                       Choice { key: "minWidth"; current: knobs.cell ? (knobs.cell.minWidth || 0) : 0
                                options: [ { v: 0, l: "Never" }, { v: 431, l: "430" }, { v: 500, l: "500" }, { v: 640, l: "640" }, { v: 800, l: "800" } ]
                                map: (v) => v === 0 ? undefined : v } }
                Knob { visible: knobs.type === "thumb"; name: "Size"
                       Num { key: "w"; from: 24; to: 96; step: 1; value: knobs.cell ? (knobs.cell.w || 48) : 48
                             onCommitted: (v) => { ed.setKnob("w", Math.round(v)); ed.setKnob("h", Math.round(v * 28 / 48)) } } }
                Knob { visible: knobs.type === "title"; name: "Text size"
                       Num { key: "size"; from: 9; to: 18; step: 1
                             value: knobs.cell ? (knobs.cell.size || (knobs.cell.lines === 1 ? 12 : 13)) : 13 } }
                Knob { visible: knobs.type === "title" || knobs.type === "artist"; name: "Max width"
                       Num { key: "maxW"; from: 0; to: 800; step: 10; value: knobs.cell ? (knobs.cell.maxW || 0) : 0
                             onCommitted: (v) => ed.setKnob("maxW", Math.round(v) > 0 ? Math.round(v) : undefined) } }
                Knob { visible: knobs.type === "title"; name: "Lines"
                       Choice { key: "lines"; current: knobs.cell ? (knobs.cell.lines || 2) : 2; options: [ { v: 1, l: "1" }, { v: 2, l: "2" } ] } }
                Knob { visible: knobs.type === "title"; name: "Artist"
                       Choice { key: "artist"; current: knobs.cell ? (knobs.cell.artist || "below") : "below"
                                options: [ { v: "below", l: "Below" }, { v: "inline", l: "Inline" }, { v: "none", l: "None" } ] } }
                Knob { visible: knobs.type === "prev" || knobs.type === "play" || knobs.type === "playdisc" || knobs.type === "next"; name: "Size"
                       Num { key: "size"; from: 18; to: 40; step: 1; value: knobs.cell ? (knobs.cell.size || 28) : 28 } }
                Knob { visible: knobs.type === "scrub"; name: "Track"
                       Num { key: "track"; from: 2; to: 12; step: 1; value: knobs.cell ? (knobs.cell.track || 6) : 6 } }
                Knob { visible: knobs.type === "scrub"; name: "Own width"
                       Num { key: "w"; from: 80; to: 600; step: 10; value: knobs.cell ? (knobs.cell.w || 200) : 200 } }
                Knob { visible: knobs.type === "time"; name: "After the elapsed"
                       Choice { key: "second"; current: knobs.cell ? (knobs.cell.second || "total") : "total"
                                options: [ { v: "total", l: "Total" }, { v: "countdown", l: "Countdown" } ]
                                map: (v) => v === "total" ? undefined : v } }
                Knob { visible: knobs.type === "button"; name: "Size"
                       Num { key: "size"; from: 16; to: 32; step: 1; value: knobs.cell ? (knobs.cell.size || 22) : 22 } }
                Knob { visible: knobs.type === "elapsed" || knobs.type === "total" || knobs.type === "countdown" || knobs.type === "time" || knobs.type === "artist"; name: "Text size"
                       Num { key: "size"; from: 9; to: 16; step: 1; value: knobs.cell ? (knobs.cell.size || 11) : 11 } }
                Knob { visible: knobs.type === "spacer"; name: "Width"
                       Num { key: "w"; from: 0; to: 240; step: 2; value: knobs.cell ? (knobs.cell.w || 16) : 16 } }
                Knob { visible: knobs.type === "volume"; name: "Width"
                       Num { key: "w"; from: 40; to: 240; step: 2; value: knobs.cell ? (knobs.cell.w || 90) : 90 } }
                Knob { visible: knobs.type === "title"; name: "Skeleton"
                       Choice { key: "skeleton"; current: knobs.cell ? knobs.cell.skeleton !== false : true; options: knobs.onOff
                                map: (v) => v ? undefined : false } }
                Knob { visible: knobs.type === "prev" || knobs.type === "play" || knobs.type === "playdisc" || knobs.type === "next"; name: "Face"
                       Role { key: "face"; current: knobs.cell ? (knobs.cell.face || "") : ""; none: "Accent" } }
                Knob { visible: !knobs.isRow; name: "Plate"
                       Role { key: "backing"; current: knobs.cell ? (knobs.cell.backing || "") : "" } }
                Knob { visible: !knobs.isRow && knobs.plate; name: "Plate pad"
                       Num { key: "backingPad"; from: 0; to: 24; step: 1; value: knobs.cell ? (knobs.cell.backingPad || 0) : 0
                             onCommitted: (v) => ed.setKnob("backingPad", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: !knobs.isRow && knobs.plate; name: "Plate drop"
                       Num { key: "backingDrop"; from: -16; to: 32; step: 1; value: knobs.cell ? (knobs.cell.backingDrop || 0) : 0
                             onCommitted: (v) => ed.setKnob("backingDrop", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: !knobs.isRow && knobs.plate; name: "Plate neck"
                       Num { key: "backingNeck"; from: 0; to: 3; step: 0.1; value: knobs.cell ? (knobs.cell.backingNeck || 0) : 0
                             onCommitted: (v) => { const n = Math.round(v * 10) / 10; ed.setKnob("backingNeck", n === 0 ? undefined : n) } } }
                Knob { visible: !knobs.isRow && knobs.plate; name: "Plate tail"
                       Num { key: "backingTail"; from: 0; to: 96; step: 1; value: knobs.cell ? (knobs.cell.backingTail || 0) : 0
                             onCommitted: (v) => ed.setKnob("backingTail", Math.round(v) === 0 ? undefined : Math.round(v)) } }
                Knob { visible: !knobs.isRow; name: "Vertical offset"
                       Num { key: "dy"; from: -12; to: 12; step: 1; value: knobs.cell ? (knobs.cell.dy || 0) : 0
                             onCommitted: (v) => ed.setKnob("dy", Math.round(v) === 0 ? undefined : Math.round(v)) } }
            }
            // add a row, done
            Row {
                width: parent.width
                spacing: Theme.gap(6)
                PushButton { id: addRowBtn; label: "Add row"; onClicked: ed.addRow() }
                PushButton {   // the picked row, or the last
                    id: dropRowBtn
                    visible: ed.rows.length > 1
                    label: "Remove row" + (Keys.isRow(ed.picked) ? " " + (ed.pickedRow + 1) : " " + ed.rows.length)
                    onClicked: ed.removeRow(Keys.isRow(ed.picked) ? ed.pickedRow : ed.rows.length - 1)
                }
                Item { width: Math.max(0, parent.width - addRowBtn.width - (ed.rows.length > 1 ? dropRowBtn.width + Theme.gap(6) : 0) - doneBtn.width - Theme.gap(12)); height: 1 }
                PushButton { id: doneBtn; label: "Done"; accent: true; onClicked: { Theme.arranging = false; ed.picked = "" } }
            }
        }
    }
}
