import QtQuick
import ".."

// Marquee-on-hover text: if the text overflows its box,
// hovering scrolls it to the end and back, looping while hovered.
// Spec: dist = overflow+8px, duration max(4, overflow/30)s, keyframes pause at
// the ends (0-15% start, 45-55% end, 85-100% back), ease-in-out.
Item {
    id: root
    property alias text: label.text
    property alias color: label.color
    property alias font: label.font
    // meaningful only when the text fits: a marquee is left-anchored while it
    // scrolls, and the label is exactly as wide as the box when it does not
    property alias horizontalAlignment: label.horizontalAlignment
    implicitHeight: label.implicitHeight
    implicitWidth: label.implicitWidth
    // Clipped only while the marquee runs. Otherwise the label is exactly the
    // box, and a halo, which reaches past the box by its size, would be cut
    // off on every side.
    clip: scrolling

    // A hover-enabled MouseArea BLOCKS hover from reaching items beneath it,
    // so inside list rows the internal HoverHandler never fires. Rows pass
    // their MouseArea here instead; we check its cursor against our bounds.
    property MouseArea hoverSource: null

    // tip: truncated text shows a full-text popup instead of the marquee
    // (grid tiles — a marquee there scrolls the title out of its own card).
    // Hovering ANYWHERE on the hoverSource (the whole tile) counts.
    property bool tip: false

    // maxLines > 1: clamped wrapping — marquee is single-line-only and stays off
    property int maxLines: 1
    // CJK line boxes run tall; grid titles tighten this a touch
    property real lineHeight: 1.0

    // Painted width, for callers centring the text themselves. Not
    // label.contentWidth: it is measured against settledWidth, which lags a window
    // drag by a size. Clamped implicitWidth is also right for a wrapping title.
    readonly property real contentW: Math.min(label.implicitWidth, width)
    readonly property real overflow: label.implicitWidth - width
    // "doesn't fit": width overflow for single-line, elision for clamped
    readonly property bool clippedText: maxLines > 1 ? label.truncated : overflow > 1
    readonly property bool extHover: hoverSource !== null && hoverSource.containsMouse
        && contains(mapFromItem(hoverSource, hoverSource.mouseX, hoverSource.mouseY))
    readonly property bool scrolling: !tip && maxLines === 1
        && (hoverSource ? extHover : hh.hovered) && overflow > 1

    readonly property bool tipHover: hoverSource ? hoverSource.containsMouse : hh.hovered
    onTipHoverChanged: {
        if (!tip) return
        if (tipHover && clippedText) tipDelay.restart()
        else { tipDelay.stop(); Tip.hide(root) }
    }
    Timer {
        id: tipDelay
        interval: 500
        onTriggered: if (root.tipHover && root.clippedText) Tip.show(label.text, root)
    }
    onVisibleChanged: if (!visible && tip) { tipDelay.stop(); Tip.hide(root) }
    Component.onDestruction: if (tip) Tip.hide(root)
    // Held at zero while the label is still. `overflow` changes with the
    // window, so otherwise every label in the app pushes a new duration into
    // the four animations below on every step of a drag: 69,000 evaluations
    // in four seconds, none of them for a running animation.
    readonly property int ms: scrolling ? Math.max(4, (overflow + 8) / 30) * 1000 : 0
    readonly property real scrollX: label.x   // test hook

    HoverHandler { id: hh; enabled: !root.hoverSource }

    // Overridable. The over-artwork ink carries the halo by default. With an ink
    // named, the halo below draws that ink's effect (Qt's style would draw the text
    // ink's on every ink), so only a plain caller with a colour uses Qt's style.
    property int textStyle: ink.length > 0 ? Text.Normal : Theme.textStyle
    property color textStyleColor: ink === "textOverArt" ? Theme.overArtStyleColor
                                                         : Theme.textStyleColor
    // With an ink named, its halo is drawn beneath the words by TextHalo from the
    // coverage of whatever draws (label or twin), and Qt's 1px style stands down so
    // the two do not stack. One layer while an effect is on, none otherwise.
    readonly property var effect: inkRole !== null ? inkRole.effect : null
    readonly property bool haloOn: effect !== null && effect.kind !== "off"
    // The ink role. Set it and the colour comes from the theme's ink entry,
    // and if that entry blends or adapts, the words are drawn through a
    // texture twin that can. Unset, this is a plain label whose caller sets
    // `color`.
    property string ink: ""
    readonly property var inkRole: ink.length > 0 ? Theme.inkRole(ink) : null
    readonly property bool adaptive: inkRole !== null && inkRole.source === "adaptive"
    readonly property bool styled: inkRole !== null && Theme.layered(inkRole)
    readonly property bool twin: inkRole !== null && (adaptive || styled || inkRole.blend.length > 0)
    // what an adaptive ink reads: the scene's ground unless a caller hands
    // over something closer (the poster passes its artwork). Without one the
    // ink inverts instead.
    property Item backdrop: Theme.backdrop
    readonly property int labelWrap: label.wrapMode
    readonly property int labelElide: label.elide
    // Theme has a property for every ink melo names, but a theme may name its
    // own (a deck's readout says `displayInk`), and `Theme[name]` is undefined
    // for those: it reaches the label as an invalid colour and draws black.
    // Theme.inkColour() resolves them.
    Binding {
        target: label; property: "color"
        value: Theme[root.ink] !== undefined ? Theme[root.ink] : Theme.inkColour(root.ink)
        when: root.ink.length > 0
    }
    // Text re-elides once the width settles (the clip cuts it meanwhile), so a resize
    // does not re-lay every label per frame. liveWidth opts out for text whose
    // placement depends on its box, such as a centred label.
    property bool liveWidth: false
    // Not Text.CurveRendering in a scrolling view: curve glyphs are geometry
    // that never shares a batch, so every batch rebuild uploads all of it
    // again. A fullscreen card grid was 17 MB a rebuild and 11% of scroll
    // frames late, against 1.7% with this default.
    property int renderType: Text.QtRendering

    property real settledWidth: width
    onWidthChanged: settleTimer.restart()
    Timer { id: settleTimer; interval: 60; onTriggered: root.settledWidth = root.width }
    Component.onCompleted: settledWidth = width

    // MELO_INK_DEBUG: what an ink-bearing label decided, once it settled
    Timer {
        running: root.ink.length > 0 && typeof MELO_INK_DEBUG !== "undefined" && MELO_INK_DEBUG
        interval: 1500
        onTriggered: console.warn("[ink]", root.ink, "text=" + root.text.substring(0, 24),
                                  "source=" + (root.inkRole ? root.inkRole.source : "-"),
                                  "twin=" + root.twin, "backdrop=" + (root.backdrop ? root.backdrop : "null"),
                                  "sameWindow=" + (root.backdrop && root.Window.window
                                                   ? (root.backdrop.Window.window === root.Window.window) : "?"),
                                  "haloOn=" + root.haloOn, "colour=" + label.color)
    }
    // The twin, loaded by source: ScrollText is in every row and tile, so nothing is
    // built and the Melo module is not needed unless the ink blends. It shares
    // `label`'s geometry and x, following the scroll animation rather than its own.
    // Nothing is built for a hidden label; the plain Text is transparent whenever
    // there is a twin, so a label coming back into view never flashes its colour.
    // keepTwin: a label about to fade in builds its twin while hidden, or its words
    // stay transparent until the layer lands and its blend joins the fade late.
    property bool keepTwin: false
    readonly property bool twinActive: twinLoader.active   // test hook
    Loader {
        id: twinLoader
        active: root.twin && (root.visible || root.keepTwin)
        x: label.x; y: label.y
        width: label.width; height: label.height
        source: "InkTwin.qml"
        onLoaded: item.host = root
    }
    // the halo, beneath whichever draws the words. Loaded by source for the
    // same reason the twin is: a row with no effect never builds it.
    Loader {
        // Beneath the twin: siblings draw in declaration order and this one
        // comes after the twin's Loader, so without z: -1 a styled halo draws
        // on top of styled words.
        z: -1
        active: root.haloOn && (root.visible || root.keepTwin)
        source: "TextHalo.qml"
        onLoaded: {
            item.label = label
            item.effect = Qt.binding(() => root.effect)
            item.colour = Qt.binding(() => Theme.inkEffectColour(root.ink))
            item.backdrop = Qt.binding(() => root.backdrop)
        }
    }

    Text {
        id: label
        renderType: root.renderType
        // still laid out when adaptive: it is what the twin above is measured
        // and positioned against, and what the scroll animation moves
        opacity: root.twin ? 0 : 1
        width: root.scrolling ? implicitWidth
             : root.liveWidth ? root.width : root.settledWidth
        elide: root.scrolling ? Text.ElideNone : Text.ElideRight
        maximumLineCount: root.maxLines
        wrapMode: root.maxLines > 1 ? Text.Wrap : Text.NoWrap
        lineHeight: root.lineHeight
        lineHeightMode: Text.ProportionalHeight
        // Qt's 1px style is the plain-label fallback; with a real halo on it
        // would stack, so it stands down
        style: root.haloOn ? Text.Normal : root.textStyle
        styleColor: root.textStyleColor
    }

    SequentialAnimation {
        // Not while the window is being resized: animation frames lag the compositor's
        // configure and it stretches the last buffer (PlaybackCoordinator stops position
        // updates for the same reason). Player is guarded so the component loads alone,
        // as in tests.
        running: root.scrolling
                 && !(typeof Player !== "undefined" && Player.uiFrozen)
        loops: Animation.Infinite
        onRunningChanged: if (!running) label.x = 0
        PauseAnimation { duration: root.ms * 0.15 }
        NumberAnimation { target: label; property: "x"; to: -(root.overflow + 8)
                          duration: root.ms * 0.30; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: root.ms * 0.10 }
        NumberAnimation { target: label; property: "x"; to: 0
                          duration: root.ms * 0.30; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: root.ms * 0.15 }
    }
}
