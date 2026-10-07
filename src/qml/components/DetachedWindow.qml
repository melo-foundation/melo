import QtQuick
import QtQuick.Window
import ".."

// The queue, the visualizer or the video in a window of its own. Where KWin can
// set its opacity it stays mapped from start to quit, and open means opacity 1
// and input, as melo and melo-mini swap: it never animates. Elsewhere it is
// shown and hidden. Its place, size, controls and keep-above are kept under
// "window.<kind>".
MeloWindow {
    id: dw
    required property string kind              // "queue" | "vis" | "video"
    readonly property bool mapped: WindowCtl.canPlaceWindows
    property bool open: false
    // the player controls over the picture: this window's choice, else the default
    property string defaultControls: "bar"
    property string controls: ""
    readonly property bool overlay: kind !== "queue" && (controls || defaultControls) === "over"
    readonly property bool hovered: hover.hovered
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
        if (!mapped) { openWindow(); return }
        applyGlass()
        const p = prefs()
        if (p.x !== undefined && p.y !== undefined) WindowCtl.moveWindows([{ title: dw.title, x: p.x, y: p.y }])
        else WindowCtl.placePopupWindowBeside(dw.title)
        if (keepAbove) WindowCtl.setWindowKeepAbove(dw, true)
        reveal(true)
    }
    function hide() {
        if (!open) return
        open = false
        if (mapped) reveal(false)
        else visible = false
    }
    // KWin's report after a user move or resize
    function reported(x, y, w, h, nearBar) {
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
            if (mapped && !open) reveal(false)
        } else if (awaitingFrame) {
            awaitingFrame = false
            framed()
        }
    }
    onWidthChanged: sizeSave.restart()
    onHeightChanged: sizeSave.restart()
    Timer {   // without KWin there is no report: the size alone is kept
        id: sizeSave
        interval: 400
        onTriggered: if (dw.open && !WindowCtl.kwinAvailable()) dw.remember({ w: dw.width, h: dw.height })
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
    Item {   // the queue's list scrolls with a drag: it moves from its top edge, or its title bar
        parent: dw.body
        width: parent.width
        height: 44
        z: 29
        enabled: dw.kind === "queue" && !dw.titled
        DragHandler {
            target: null
            acceptedModifiers: Qt.NoModifier
            grabPermissions: PointerHandler.CanTakeOverFromAnything   // over the header's buttons
            onActiveChanged: if (active) dw.startSystemMove()
        }
    }
    Item {   // over it: Ctrl+drag, let go next to the bar, goes back under it
        parent: dw.body
        anchors.fill: parent
        z: 30
        HoverHandler { id: hover }
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
