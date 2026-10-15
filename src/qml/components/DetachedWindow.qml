import QtQuick
import QtQuick.Window
import ".."
import "layoutstate.js" as LayoutState

// The queue, the visualizer or the video in a window of its own. Where KWin can
// set its opacity it stays mapped from start to quit, and open means opacity 1
// and input, as melo and melo-mini swap: it never animates. Elsewhere it is
// shown and hidden. Its place, size, controls, keep-above and whether it is open
// are kept under "window.<kind>".
MeloWindow {
    id: dw
    required property string kind              // "queue" | "vis" | "video"
    readonly property bool mapped: WindowCtl.canPlaceWindows
    property bool open: false
    // the player controls over the picture: this window's choice, else the default
    property string defaultControls: "bar"
    property string controls: ""
    readonly property bool overlay: kind !== "queue" && (controls || defaultControls) === "over"
    // a resize takes the pointer, so hover reads false: held through it, or every fade
    // that follows hover animates mid-resize (docs/mini-player-windowing.md §3)
    property bool resizing: false
    property bool hovered: false
    Binding on hovered { value: hover.hovered; when: !dw.resizing; restoreMode: Binding.RestoreNone }
    // set by a Ctrl+drag; let go next to the bar, the window asks to go back under it
    property bool reattachArmed: false
    // armed by whoever waits on this window's next frame (a swap)
    property bool awaitingFrame: false
    signal framed()
    signal reattachRequested()
    // a right click anywhere in the window, at (x, y) in its coordinates
    signal menuRequested(real x, real y)

    title: "melo-" + kind
    heading: kind === "queue" ? "Queue" : kind === "vis" ? "Visualizer" : "Video"
    titled: Theme.popupFrame === "title"
    resizable: true
    minimumWidth: 240
    minimumHeight: 120
    width: 420
    height: 400
    hideOnClose: false
    visible: mapped
    onCloseRequested: hide()
    // nothing drawn while closed, under the compositor's opacity 0 as well
    Binding { target: dw.contentItem; property: "opacity"; value: dw.open ? 1 : 0 }

    readonly property string key: "window." + kind
    function prefs() {
        const p = Settings.uiGet(key, null)
        return p && typeof p === "object" ? p : ({})
    }
    function remember(fields) { Settings.uiSet(key, Object.assign({}, prefs(), fields)) }
    function restore() {
        const p = prefs()
        if (p.w > 0 && p.h > 0) { width = p.w; height = p.h }
        controls = p.controls === "bar" || p.controls === "over" ? p.controls : ""
        keepAbove = p.above === true
    }
    function setControls(c) { controls = c; remember({ controls: c }) }
    // above the other windows, remembered; applied whenever it opens
    property bool keepAbove: false
    function setKeepAbove(on) { keepAbove = on; remember({ above: on }); WindowCtl.setWindowKeepAbove(dw, on) }

    function reveal(on) {
        WindowCtl.setInputEnabled(dw, on)
        WindowCtl.setWindowOpacities([{ title: dw.title, opacity: on ? 1 : 0 }])
    }
    // open where it was left
    function show() {
        if (open) return
        open = true
        if (!mapped) {
            // X11 without KWin: Qt places it, at its saved place if that is on a screen
            const s = prefs()
            if (x11Places && s.x !== undefined && s.y !== undefined) {
                const at = LayoutState.onScreen(s.x, s.y, width, height, Array.prototype.map.call(Qt.application.screens,
                    r => ({ x: r.virtualX, y: r.virtualY, width: r.width, height: r.height })))
                if (at) { x = at.x; y = at.y }
            }
            openWindow()
            return
        }
        applyGlass()
        const p = prefs()
        if (p.x !== undefined && p.y !== undefined) WindowCtl.moveWindows([{ title: dw.title, x: p.x, y: p.y }])
        else WindowCtl.placePopupWindowBeside(dw.title)
        if (keepAbove) WindowCtl.setWindowKeepAbove(dw, true)
        WindowCtl.raisePopupWindow(dw.title)
        reveal(true)
    }
    // open at start: waits for the first frame, before which KWin cannot place it
    property bool reopenPending: false
    function reopen() {
        if (settled || !mapped) show()
        else reopenPending = true
    }
    // whether it is open, kept with its place; off while melo quits
    property bool recordOpen: false
    onOpenChanged: if (recordOpen) remember({ open: open })
    function hide() {
        if (!open) return
        open = false
        if (mapped) reveal(false)
        else visible = false
    }
    // KWin's report after a user move or resize
    function reported(x, y, w, h, nearBar) {
        if (MELO_GEOM_DEBUG) {
            const c = WindowCtl.cursorPos()
            console.warn("[detach] " + Date.now() + " " + kind + " end cursor " + c.x + "," + c.y + " window " + x + "," + y)
        }
        remember({ x: x, y: y, w: w, h: h })
        const back = reattachArmed && nearBar
        reattachArmed = false
        if (back) reattachRequested()
    }

    // closed and click-through from its first frame, once the surface exists
    property bool settled: false
    onFrameSwapped: {
        if (!settled) {
            settled = true
            if (reopenPending) { reopenPending = false; show() }
            else if (mapped && !open) reveal(false)
        } else if (awaitingFrame) {
            awaitingFrame = false
            framed()
        }
    }
    readonly property bool x11Places: !mapped && Qt.platform.pluginName === "xcb"
    onWidthChanged: sizeSave.restart()
    onHeightChanged: sizeSave.restart()
    onXChanged: if (x11Places) sizeSave.restart()
    onYChanged: if (x11Places) sizeSave.restart()
    Timer {   // without KWin there is no report: the size is kept, and on X11 the place
        id: sizeSave
        interval: 400
        onTriggered: {
            if (!dw.open) return
            if (dw.x11Places) dw.remember({ x: dw.x, y: dw.y, w: dw.width, h: dw.height })
            else if (!WindowCtl.kwinAvailable()) dw.remember({ w: dw.width, h: dw.height })
        }
    }
    Item {   // under the content: a drag the content leaves moves the window
        parent: dw.body
        anchors.fill: parent
        z: -1
        enabled: dw.kind !== "queue"
        DragHandler {
            target: null
            acceptedModifiers: Qt.NoModifier
            onActiveChanged: if (active) dw.startSystemMove()
        }
    }
    // on the body, not an item over it: one over the content takes its hover (the visualizer's gear)
    HoverHandler { id: hover; parent: dw.body }
    // the queue has no rows: a drag anywhere moves it
    property bool listEmpty: false
    Item {   // the queue's list scrolls with a drag: it moves from its top edge, or its title bar
        parent: dw.body
        width: parent.width
        height: dw.listEmpty ? parent.height : 44
        // under the header: over it, it would take the tabs' and buttons' presses
        z: -1
        enabled: dw.kind === "queue" && (!dw.titled || dw.listEmpty)
        DragHandler {
            target: null
            acceptedModifiers: Qt.NoModifier
            // never from an item: a press a tab or a button took stays theirs, however far it wanders
            grabPermissions: PointerHandler.CanTakeOverFromHandlersOfDifferentType | PointerHandler.ApprovesTakeOverByAnything
            onActiveChanged: if (active) dw.startSystemMove()
        }
    }
    Item {   // over it: Ctrl+drag, let go next to the bar, goes back under it
        parent: dw.body
        anchors.fill: parent
        z: 30
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: (ev) => {
                const g = parent.mapToItem(null, ev.position.x, ev.position.y)
                dw.menuRequested(g.x, g.y)
            }
        }
        DragHandler {
            target: null
            acceptedModifiers: Qt.ControlModifier
            grabPermissions: PointerHandler.CanTakeOverFromAnything   // a queue row holds its press
            onActiveChanged: if (active) { dw.reattachArmed = true; dw.startSystemMove() }
        }
    }
}
