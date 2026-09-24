import QtQuick
import QtQuick.Effects
import ".."

// Skeleton placeholder and rounded thumbnail container.
// - Ground: the skeleton role. A flat role is a plain Rectangle; a role with a
//   fill gets a Surface under it. Hundreds are live and a GridView builds dozens
//   mid-drag inside polish, so Theme.skeletonStyled is asked once, not per item.
// - Style (Theme.skeletonStyle): shimmer, pulse or still. The shimmer is the
//   ground Rectangle's own gradient, so it stays inside the rounded shape (an
//   overlaid sweep clips square).
// - Children (thumbnails, badges) are masked to the rounded shape, since QML
//   clip is rectangular. bottomRadius can differ (grid cards: square bottom).
Item {
    id: skel
    property bool shimmer: true      // the site's: false is a plain container
    // The styled fill (a whole Surface chain) is built only for a skeleton that is
    // seen; built always, a tile's three skeletons took it from 1.87 to 4.78 ms.
    // A text bar hides via `visible` when its words arrive; the artwork container
    // stays visible under its picture, which only the caller knows: `needed`. Once
    // shown it is kept, so a shimmer does not churn it.
    property bool needed: true
    property bool everShown: false
    // `shown` debounces `needed`: a recycled card's cached picture takes a frame or
    // two to decode, so `needed` flicks on every reuse. `shown` drops at once but
    // rises only after 120ms true; at construction it is bound to `needed`, so a
    // first load shows placeholders immediately. `loading` (refresh, chip change)
    // also shows them at once, whichever property changes first.
    property bool loading: false
    property bool shown: needed
    property Timer appearTimer: Timer { interval: 120; onTriggered: skel.shown = skel.needed }
    onNeededChanged: {
        if (!needed) { appearTimer.stop(); shown = false }
        else if (loading) { appearTimer.stop(); shown = true }
        else appearTimer.restart()
    }
    onLoadingChanged: if (loading && needed) { appearTimer.stop(); shown = true }
    onShownChanged: if (shown && visible) everShown = true
    onVisibleChanged: if (visible && shown) everShown = true
    // A skeleton shown from the start latches too: `visible` never changes on one
    // built visible, so its fill chain would be torn down when the picture arrives and
    // rebuilt on reuse, each teardown walking the window's connection list once per
    // `Window` attached property in the subtree. Latching: -16% cycles a card.
    Component.onCompleted: if (visible && shown) everShown = true
    property real radius: Theme.radiusSm   // theme-reactive: rounded/squared corner style
    property real bottomRadius: radius
    readonly property string style: Theme.skeletonStyle
    readonly property bool sweeping: shimmer && style === "shimmer"
    readonly property bool pulsing: shimmer && style === "pulse"

    // the skeleton role: its colour, and the sheen a step lighter at the
    // same alpha
    readonly property color base: Theme.skeleton
    readonly property color hi: {
        const l = Qt.lighter(Qt.rgba(base.r, base.g, base.b, 1), 1.45)
        return Qt.rgba(l.r, l.g, l.b, Math.min(1, base.a * 1.15))
    }
    // only a role that would blend gets a Surface built
    readonly property bool styled: Theme.skeletonStyled
    property real sheenPos: -0.3
    function cl(p) { return Math.max(0, Math.min(1, p)) }

    // children declared at usage sites land in contentItem and get masked
    default property alias content: contentItem.data

    Rectangle {
        id: ground
        objectName: "skeletonGround"
        anchors.fill: parent
        color: skel.styled ? "transparent" : skel.base
        topLeftRadius: skel.radius
        topRightRadius: skel.radius
        bottomLeftRadius: skel.bottomRadius
        bottomRightRadius: skel.bottomRadius
        opacity: 1
        gradient: skel.sweeping ? sheenGrad : null
        Gradient {
            id: sheenGrad
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: skel.styled ? "transparent" : skel.base }
            GradientStop { position: skel.cl(skel.sheenPos - 0.25); color: skel.styled ? "transparent" : skel.base }
            GradientStop { position: skel.cl(skel.sheenPos); color: skel.hi }
            GradientStop { position: skel.cl(skel.sheenPos + 0.25); color: skel.styled ? "transparent" : skel.base }
            GradientStop { position: 1.0; color: skel.styled ? "transparent" : skel.base }
        }
        // z below the ground's own content: the sheen draws over the fill
        Loader {
            objectName: "skeletonFill"
            anchors.fill: parent
            z: -1
            active: skel.styled && (skel.everShown || (skel.visible && skel.shown))
            // Hidden, not destroyed, once the picture covers it — the latch
            // above keeps the chain and this stops it drawing. An invisible
            // subtree is not rendered, so a covered fill costs nothing a frame.
            visible: skel.shown
            sourceComponent: Surface {
                role: "skeleton"
                topLeftRadius: skel.radius
                topRightRadius: skel.radius
                bottomLeftRadius: skel.bottomRadius
                bottomRightRadius: skel.bottomRadius
            }
        }
        SequentialAnimation on opacity {
            running: skel.visible && skel.pulsing && skel.opacity > 0
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.45; to: 1; duration: 700; easing.type: Easing.InOutQuad }
            // a pulse that stops mid-breath leaves the ground dim
            onRunningChanged: if (!running) ground.opacity = 1
        }
    }
    NumberAnimation on sheenPos {
        running: skel.visible && skel.sweeping && skel.opacity > 0
        loops: Animation.Infinite
        from: -0.3; to: 1.3
        duration: 1500
        easing.type: Easing.InOutQuad
    }

    Item {
        id: contentItem
        anchors.fill: parent
        // only pay for the mask when there's content and actual rounding
        layer.enabled: children.length > 0
                       && (skel.radius > 0 || skel.bottomRadius > 0)
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: maskRect
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
    }
    Rectangle {
        id: maskRect
        anchors.fill: parent
        topLeftRadius: skel.radius
        topRightRadius: skel.radius
        bottomLeftRadius: skel.bottomRadius
        bottomRightRadius: skel.bottomRadius
        color: "#ffffff"
        visible: false
        layer.enabled: true
        layer.smooth: true
    }
}
