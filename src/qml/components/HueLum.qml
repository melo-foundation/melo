import QtQuick
import QtQuick.Window
import ".."

// The backdrop, re-coloured, drawn where this item is. Unlike a hardware blend it
// has no framebuffer to read, so `backdrop` names the item whose colours it adapts
// to. The backdrop is a layer sampled directly with a sub-rect: one texture
// however many surfaces read it.
Item {
    id: root

    property Item backdrop
    // An item with layer.enabled whose alpha is the coverage — glyphs, for
    // text. Null fills the whole item, which is the surface case.
    property Item mask: null

    // -1..1 each. See huelum.frag for what the numbers mean; the short
    // version is that negative lum inverts and positive lum flips away from
    // mid-grey, which is the one that cannot fail on a mid-tone backdrop.
    property real hue: 0
    property real lum: 0
    property real sat: 0

    // A ShaderEffect reads only items in its own window; otherwise Qt refuses and
    // warns ("Cannot use same item on different windows"). Secondary windows hand
    // their readers the main window's ground, so the check is made here.
    readonly property bool ready: backdrop !== null
        && backdrop.Window.window === root.Window.window
    // The backdrop is always a layer, read with srcRect; one that is not is made one
    // here, a side effect cheaper than a second read path. Except the scene's own
    // ground: its layer is bound to the count below, and writing it here would break
    // that binding and leave the full-window pass on for good.
    function ensureLayer() {
        if (backdrop === Theme.backdrop) return
        if (backdrop && backdrop.layer && !backdrop.layer.enabled) backdrop.layer.enabled = true
    }

    // One hold on the ground while this is drawing. Imperative rather than a
    // binding with a signal handler: a counter is a delta, and a change signal
    // that fires once during creation and again at completion double-counts.
    property bool counted: false
    function recount() {
        // ...only for readers of the ground. A HueLum given a backdrop of its
        // own — the artwork under a window surface — reads that and not
        // Theme.backdrop, and holding the ground's layer open for it would
        // pay the full-window pass for a texture nothing samples.
        const want = ready && visible && backdrop === Theme.backdrop
        const live = ready && visible
        if (live !== living) { living = live; Theme.adaptiveLive += live ? 1 : -1 }
        if (want === counted) return
        counted = want
        Theme.adaptiveUsers += want ? 1 : -1
    }
    // ...and one on the slow tick for ANY live reader, ground or not: a
    // reader of the artwork still has to follow its window when the tick
    // is the only thing that re-maps it
    property bool living: false
    // `ready` arrives after completion (the backdrop's layer is switched on
    // here and its texture lands a frame later), and the map at completion
    // bails on it, so a reader that never moves would sample from nought.
    onReadyChanged: { recount(); updateRect() }
    onXChanged: updateRect()
    onYChanged: updateRect()
    onVisibleChanged: recount()
    Component.onDestruction: { if (counted) Theme.adaptiveUsers -= 1; if (living) Theme.adaptiveLive -= 1 }
    onBackdropChanged: { ensureLayer(); updateRect(); recount() }
    readonly property bool direct: ready && backdrop.layer !== undefined
                                   && backdrop.layer.enabled === true

    // Where this item is in the backdrop, normalised
    property rect srcRect: Qt.rect(0, 0, 1, 1)
    function updateRect() {
        if (!ready) return
        const p = root.mapToItem(backdrop, 0, 0)
        restPx = p.x; restPy = p.y
        if (scroller) { restCx = scroller.contentX; restCy = scroller.contentY }
        putRect(p.x, p.y)
    }
    onWidthChanged: updateRect()
    onHeightChanged: updateRect()

    // mapToItem is not reactive, and remapping every frame is JS per instance. As in
    // StyledFill, the map is taken at rest (slow tick, size change) and while a
    // scroller moves the position is that minus the content's travel since.
    property real restPx: 0
    property real restPy: 0
    property real restCx: 0
    property real restCy: 0
    function putRect(x, y) {
        // `ready` is a binding and every caller here is a signal handler, so
        // the two disagree for the turn in which a backdrop is destroyed under
        // one (a poster copy going with its artwork), and the map would run on
        // a dead object.
        if (!backdrop) return
        const W = Math.max(1, backdrop.width), H = Math.max(1, backdrop.height)
        srcRect = Qt.rect(x / W, y / H, width / W, height / H)
    }
    function followContent() {
        if (!ready || !scroller) return
        putRect(restPx - (scroller.contentX - restCx), restPy - (scroller.contentY - restCy))
    }
    // The walk up is once per instance, not once per frame.
    property Item scroller: null
    function findScroller() {
        let p = parent
        while (p) {
            if (p.flickableDirection !== undefined && p.contentY !== undefined) return p
            p = p.parent
        }
        return null
    }
    Component.onCompleted: { scroller = findScroller(); ensureLayer(); updateRect(); recount() }
    Window.onWindowChanged: { scroller = findScroller(); updateRect() }
    Connections {
        target: Theme
        enabled: root.ready && root.visible
        function onSlowTickChanged() { root.updateRect() }
    }
    Connections {
        target: root.ready && root.visible ? root.scroller : null
        function onContentXChanged() { root.followContent() }
        function onContentYChanged() { root.followContent() }
    }

    ShaderEffect {
        anchors.fill: parent
        visible: root.direct
        fragmentShader: Qt.resolvedUrl("huelum.frag.qsb")
        blending: true
        property variant source: root.direct ? root.backdrop : null
        property rect srcRect: root.srcRect
        // Every declared sampler must be bound, so the unmasked case binds the backdrop
        // twice, but only when `direct` says it is in this window: bound across windows,
        // Qt refuses it and that window's backdrop readers stop drawing until restart.
        property variant mask: root.mask ? root.mask : (root.direct ? root.backdrop : null)
        property real hasMask: root.mask ? 1 : 0
        property real hue: root.hue
        property real lum: root.lum
        property real sat: root.sat
    }
}
