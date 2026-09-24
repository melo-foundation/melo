import QtQuick
import QtQuick.Window
import Melo 1.0
import ".."

// The blending half of Surface.qml, in its own file so that `import Melo`
// is only paid for when a role actually blends. `host` is the Surface.
Item {
    id: bs
    property Item host: null
    readonly property bool adaptive: host ? host.adaptive : false
    readonly property string blend: host ? host.blend : ""
    readonly property string hwMode: host ? host.hwMode : "normal"
    readonly property vector4d amounts: host ? host.adaptiveAmounts : Qt.vector4d(0, -1, 0, 1)
    readonly property color colour: host ? host.color : "transparent"
    readonly property bool styled: host ? host.styled : false
    readonly property string kind: host ? host.source : ""
    readonly property var params: host ? host.styledParams : Theme.styledOf(null)
    readonly property var layers: host ? host.styledLayers : null
    readonly property real fillOpacity: host ? host.fillOpacity : 1

    // A shader paints its whole rectangle and the radius lives on the hidden
    // Rectangle, so the rounded shape is rendered as coverage and handed to the fill
    // as its mask. A square surface builds no layer.
    readonly property bool rounded: host ? (host.radius > 0 || host.topLeftRadius > 0 || host.topRightRadius > 0
                                            || host.bottomLeftRadius > 0 || host.bottomRightRadius > 0) : false
    // The coverage target keeps its last settled size instead of reallocating per
    // resize step; the fill samples it in uv, so corners go briefly elliptical until
    // the drag stops.
    property real settledWidth: width
    property real settledHeight: height
    readonly property bool settling: width !== settledWidth || height !== settledHeight
    // The first real size to arrive is taken at once, or the first hundred milliseconds of the window are a
    // held 0x0 texture — nothing at all.
    function resize() {
        if (settledWidth > 0 && settledHeight > 0) cornerSettle.restart()
        else { settledWidth = width; settledHeight = height }
    }
    // Once per turn: a resize step changes width and height separately, which
    // would restart the settle twice a step for every surface in the window.
    onWidthChanged: Qt.callLater(resize)
    onHeightChanged: Qt.callLater(resize)
    Component.onCompleted: {
        settledWidth = width; settledHeight = height; cornerSettle.stop()
        Qt.callLater(rebindMask)
    }
    Timer {
        id: cornerSettle
        interval: 100
        onTriggered: { bs.settledWidth = bs.width; bs.settledHeight = bs.height }
    }
    // Coverage depends only on size and the four radii, so the window's FillCache
    // holds one per shape and a grid of cards shares it. Keyed on the settled size so
    // a drag does not create and evict a shape per step.
    readonly property real rTL: host && host.topLeftRadius >= 0 ? host.topLeftRadius : (host ? host.radius : 0)
    readonly property real rTR: host && host.topRightRadius >= 0 ? host.topRightRadius : (host ? host.radius : 0)
    readonly property real rBL: host && host.bottomLeftRadius >= 0 ? host.bottomLeftRadius : (host ? host.radius : 0)
    readonly property real rBR: host && host.bottomRightRadius >= 0 ? host.bottomRightRadius : (host ? host.radius : 0)
    // Clockwise from the top left, and only for a shape that really is a
    // rounded rectangle: the shader then has the distance in closed form and
    // needs neither the field nor the nine taps over it.
    readonly property vector4d rad: rounded ? Qt.vector4d(rTL, rTR, rBR, rBL)
                                            : Qt.vector4d(-1, -1, -1, -1)
    readonly property string maskKey: rounded && settledWidth > 0 && settledHeight > 0
        ? "m:" + settledWidth + ":" + settledHeight + ":"
          + rTL + ":" + rTR + ":" + rBL + ":" + rBR
        : ""
    property Item cornerMask: null
    property Item cache: null
    property string heldKey: ""
    // The new one first, the old one after. Releasing first would drop a shape
    // to zero references and, where the new key is the same shape by another
    // route, start its grace timer for nothing; and writing cornerMask to null
    // in between makes every reader tear its field down and build it again.
    function rebindMask() {
        const c = Theme.fillCache(Window.window)
        if (c !== cache) {
            if (heldKey.length > 0 && cache) cache.release(heldKey)
            heldKey = ""
            cache = c
        }
        if (!cache) { cornerMask = null; return }
        if (heldKey === maskKey) return
        const old = heldKey
        heldKey = maskKey
        cornerMask = maskKey.length > 0
            ? cache.mask(maskKey, ({ width: settledWidth, height: settledHeight,
                                     radius: host ? host.radius : 0,
                                     topLeftRadius: rTL, topRightRadius: rTR,
                                     bottomLeftRadius: rBL, bottomRightRadius: rBR }))
            : null
        if (old.length > 0) cache.release(old)
    }
    // Once the key has stopped moving, not on every step to it. A surface's
    // four corner radii are four separate property writes, so a card built with
    // one radius walks 0:0:0:0, 3:0:0:0, 3:3:0:0, 3:3:3:0 and only then
    // 3:3:3:3: five shapes, four of them left in the cache to time out. Qt.callLater collapses the run into the one key that stuck.
    onMaskKeyChanged: Qt.callLater(rebindMask)
    Window.onWindowChanged: Qt.callLater(rebindMask)
    Component.onDestruction: if (heldKey.length > 0 && cache) cache.release(heldKey)

    // Only the path that draws is built; a styled surface with no mode builds no
    // blended twin, adaptive shader, adaptive twin or BlendRect. Latched once built,
    // like Surface's `everBlended`: a list row flips `role` on hover, and a mode on
    // one side only would build and tear down a render target twice per row.
    readonly property bool wantSource: styled && blend.length > 0
    readonly property bool wantAdaptivePlain: adaptive && blend.length === 0
    readonly property bool wantAdaptiveSource: adaptive && blend.length > 0
    // Read off `host`, not the properties above: Surface sets `host` in onLoaded,
    // and until `styled` re-evaluates they would make this true (it is the path for
    // a surface told nothing) and latch it on, leaving every surface a BlendRect it
    // never draws.
    readonly property bool wantRect: host !== null
        && !((host.adaptive || host.styled) && host.blend.length === 0)
    property bool hadSource: false
    property bool hadAdaptivePlain: false
    property bool hadAdaptiveSource: false
    property bool hadRect: false
    onWantSourceChanged: if (wantSource) hadSource = true
    onWantAdaptivePlainChanged: if (wantAdaptivePlain) hadAdaptivePlain = true
    onWantAdaptiveSourceChanged: if (wantAdaptiveSource) hadAdaptiveSource = true
    onWantRectChanged: if (wantRect) hadRect = true
    // ...for this palette only, the same end Surface's own latch takes.
    readonly property int palGen: Theme.paletteGen
    onPalGenChanged: {
        hadSource = wantSource; hadAdaptivePlain = wantAdaptivePlain
        hadAdaptiveSource = wantAdaptiveSource; hadRect = wantRect
    }

    // styled: the fill drawn plainly, or to a texture BlendRect draws with the mode
    StyledFill {
        id: styledPlain
        anchors.fill: parent
        visible: bs.styled && bs.blend.length === 0
        kind: bs.kind; params: bs.params; colourA: bs.colour
        layers: bs.layers
        backdrop: bs.host ? bs.host.backdrop : null
        mask: bs.cornerMask
        maskKey: bs.maskKey
        rad: bs.rad
        coarseField: true
        opacity: bs.fillOpacity
        // drawn straight over Surface's ground, which paints the role colour
        groundColour: bs.host ? bs.host.color : "transparent"
    }
    // The Loader IS the zero-sized clip: a source only has a texture if it
    // actually renders, and one that renders also draws unless something clips
    // it away.
    Loader {
        id: styledSource
        width: 0; height: 0; clip: true
        visible: bs.wantSource
        active: bs.wantSource || bs.hadSource
        sourceComponent: StyledFill {
            width: bs.width; height: bs.height
            kind: bs.kind; params: bs.params; colourA: bs.colour
            layers: bs.layers
            backdrop: bs.host ? bs.host.backdrop : null
            mask: bs.cornerMask
            maskKey: bs.maskKey
            rad: bs.rad
            coarseField: true
            opacity: bs.fillOpacity
            layer.enabled: true
        }
    }

    // Plain alpha-over: the source alone, no hardware mode to apply.
    Loader {
        anchors.fill: parent
        visible: bs.wantAdaptivePlain
        active: bs.wantAdaptivePlain || bs.hadAdaptivePlain
        sourceComponent: HueLum {
            anchors.fill: parent
            backdrop: bs.wantAdaptivePlain && bs.host ? bs.host.backdrop : null
            mask: bs.cornerMask
            hue: bs.amounts.x
            lum: bs.amounts.y
            sat: bs.amounts.z
            opacity: bs.amounts.w
        }
    }

    // Adaptive AND a mode: the shader renders to a texture and BlendRect draws
    // that texture with the hardware factors.
    Loader {
        id: adaptiveSource
        width: 0; height: 0; clip: true
        visible: bs.wantAdaptiveSource
        active: bs.wantAdaptiveSource || bs.hadAdaptiveSource
        sourceComponent: HueLum {
            width: bs.width
            height: bs.height
            backdrop: bs.adaptive && bs.host ? bs.host.backdrop : null
            mask: bs.cornerMask
            hue: bs.amounts.x
            lum: bs.amounts.y
            sat: bs.amounts.z
            opacity: bs.amounts.w
            layer.enabled: true
        }
    }

    Loader {
        anchors.fill: parent
        visible: bs.wantRect
        active: bs.wantRect || bs.hadRect
        sourceComponent: BlendRect {
            anchors.fill: parent
            // Full alpha: opacity sliders do not apply to a hardware mode (half an invert is
            // not expressible). White for a plain invert, a tint for the rest.
            color: Qt.rgba(bs.colour.r, bs.colour.g, bs.colour.b, 1)
            source: bs.blend.length > 0
                    ? (bs.adaptive ? adaptiveSource.item : bs.styled ? styledSource.item : null) : null
            mode: bs.hwMode
        }
    }
}
