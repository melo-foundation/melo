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
    // warns ("Cannot use same item on different windows"). A reader of the main
    // ground in another window reads that window's ground (Theme.groundOf), and a
    // ground is sampled through its readItem, which has the video in it.
    readonly property Item ground: Theme.groundFor(backdrop, root.Window.window)
    readonly property Item src: Theme.sampled(backdrop, root.Window.window)
    readonly property bool ready: src !== null
        && src.Window.window === root.Window.window
    // The backdrop is always a layer, read with srcRect; one that is not is made one
    // here, a side effect cheaper than a second read path. Never a ground or its read
    // texture: their layers are bound to the count below. Decided by `backdrop`, as
    // `ground` can lag `src` within one change.
    function ensureLayer() {
        if (backdrop === Theme.backdrop) return
        if (src && src.layer && !src.layer.enabled) src.layer.enabled = true
    }

    // One hold on the ground while this is drawing. Imperative rather than a
    // binding with a signal handler: a counter is a delta, and a change signal
    // that fires once during creation and again at completion double-counts.
    property bool counted: false
    property Item countedOn: null
    function recount() {
        // ...only for readers of a ground. A HueLum given a backdrop of its
        // own — the artwork under a window surface — reads that and not
        // Theme.backdrop, and holding the ground's layer open for it would
        // pay the full-window pass for a texture nothing samples.
        const want = ready && visible && ground !== null
        const live = ready && visible
        if (live !== living) { living = live; Theme.adaptiveLive += live ? 1 : -1 }
        if (want === counted && (!want || countedOn === ground)) return
        release()
        if (!want) return
        counted = true
        countedOn = ground
        Theme.holdGround(ground, 1)
    }
    function release() {
        if (!counted) return
        Theme.holdGround(countedOn, -1)
        counted = false
        countedOn = null
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
    Component.onDestruction: { release(); if (living) Theme.adaptiveLive -= 1 }
    onSrcChanged: { ensureLayer(); updateRect(); recount() }
    onGroundChanged: recount()
    readonly property bool direct: ready && src.layer !== undefined
                                   && src.layer.enabled === true

    // Where this item is in the backdrop, normalised
    property rect srcRect: Qt.rect(0, 0, 1, 1)
    function updateRect() {
        if (!ready) return
        const p = root.mapToItem(src, 0, 0)
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
        if (!src) return
        const W = Math.max(1, src.width), H = Math.max(1, src.height)
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
        property variant source: root.direct ? root.src : null
        property rect srcRect: root.srcRect
        // Every declared sampler must be bound, so the unmasked case binds the backdrop
        // twice, but only when `direct` says it is in this window: bound across windows,
        // Qt refuses it and that window's backdrop readers stop drawing until restart.
        property variant mask: root.mask ? root.mask : (root.direct ? root.src : null)
        property real hasMask: root.mask ? 1 : 0
        property real hue: root.hue
        property real lum: root.lum
        property real sat: root.sat
    }
}
