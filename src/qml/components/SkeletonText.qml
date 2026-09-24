import QtQuick
import ".."

// Text with a loading skeleton that morphs into the content: while `loading` a
// shimmer bar of placeholderWidth shows; when the text arrives the bar stretches to
// its measured width, then dissolves into it. The label is a ScrollText.
// Driven imperatively, not by a state Transition: the width target must be
// measured a tick after `loading` flips (the text lands in the same model.set(),
// and a transition captures its end values first), and an explicit `to:` in a
// Transition permanently clobbers the property's binding, so the bar's width is
// re-assigned on each loading entry. Entering `loading` is instant; a fade-in
// reads as a blank dip over just-cleared content.
Item {
    id: root
    property alias text: label.text
    property alias ink: label.ink
    property alias renderType: label.renderType
    property alias color: label.color
    property alias font: label.font
    property alias hoverSource: label.hoverSource
    property alias tip: label.tip
    property alias maxLines: label.maxLines
    property alias lineHeight: label.lineHeight
    property bool loading: false
    property bool shimmer: true
    property bool morph: true        // false: crossfade only (grid tiles)
    // A guess at how long the text will be. The list views' guesses are
    // measured: 60 real YouTube search results rendered in the design font
    // give a title of 180px at p15 and 440px at p85 (median 289), and a
    // "channel · views · age" line of 165px to 210px.
    property real placeholderWidth: 120
    property real barHeight: 12
    property real barOffset: 0   // vertical nudge, centre-aligned bars only
    // bar vertical alignment within the text line: rows pair a top-aligned
    // title bar with a bottom-aligned channel bar so the skeleton block's
    // edges line up with the 36px thumbnail beside it
    property string barAlign: "center"

    implicitHeight: Math.max(label.implicitHeight, barHeight)
    // A placeholder is a fixed-pixel guess at the text's length, so the bar is
    // clamped to the item's width; in a narrower column it would run under
    // whatever sits to its right.
    readonly property real barW: root.width > 0
                                 ? Math.min(placeholderWidth, root.width)
                                 : placeholderWidth
    // The request is the whole guess; only the drawn bar is clamped. A compact row
    // sizes the title against its meta, so clamping the request to the width it
    // decides is a loop that QML settles at the layout's floor.
    implicitWidth: loading ? placeholderWidth : label.implicitWidth
    readonly property real barOpacity: bar ? bar.opacity : 0     // test hooks
    readonly property real barWidth: bar ? bar.width : 0
    readonly property real labelOpacity: label.opacity

    // The bar is built only once `loading` has been true (rows that already have text
    // skip a ground, Loader and shimmer), then kept like Surface's fill chain so the
    // morph back out has something to animate.
    property bool everLoaded: false
    readonly property alias bar: barLoader.item
    Loader {
        id: barLoader
        active: root.loading || root.everLoaded
        // Re-run once the bar exists: it is created at opacity 0 and only enterLoading()
        // lifts it. Where `loading` is true from the first frame (the player bar at
        // startup), Component.onCompleted's call loses to the item's own opacity binding
        // and `loading` never changes to retry, so the placeholder would stay invisible
        // for the session.
        onLoaded: if (root.loading) root.enterLoading()
        anchors.verticalCenter: root.barAlign === "center" ? parent.verticalCenter : undefined
        anchors.verticalCenterOffset: root.barOffset
        anchors.top: root.barAlign === "top" ? parent.top : undefined
        anchors.bottom: root.barAlign === "bottom" ? parent.bottom : undefined
        sourceComponent: Skeleton {
            width: root.barW
            height: root.barHeight
            radius: Theme.squared ? 0 : 3
            shimmer: root.shimmer
            opacity: 0
            visible: opacity > 0.01
        }
    }

    ScrollText {
        id: label
        width: root.width
        anchors.verticalCenter: parent.verticalCenter
        opacity: 1
    }

    Component.onCompleted: if (loading) { everLoaded = true; enterLoading() }
    onLoadingChanged: {
        if (loading) { everLoaded = true; enterLoading() }
        else Qt.callLater(leaveLoading)   // next tick: arriving text measured
    }
    function enterLoading() {
        morphSeq.stop()
        fadePar.stop()
        if (!bar) return
        bar.width = root.barW
        bar.opacity = 1
        label.opacity = 0
    }
    function leaveLoading() {
        if (loading) return   // flipped back before the tick
        if (morph) {
            morphSeq.toW = Math.max(1, Math.min(label.implicitWidth, root.width))
            morphSeq.restart()
        } else {
            fadePar.restart()
        }
    }

    SequentialAnimation {
        id: morphSeq
        property real toW: 100
        NumberAnimation { target: bar; property: "width"; to: morphSeq.toW
                          duration: 180; easing.type: Easing.OutCubic }
        ParallelAnimation {
            NumberAnimation { target: bar; property: "opacity"; to: 0; duration: 220 }
            NumberAnimation { target: label; property: "opacity"; to: 1; duration: 220 }
        }
    }
    ParallelAnimation {
        id: fadePar
        NumberAnimation { target: bar; property: "opacity"; to: 0; duration: 250 }
        NumberAnimation { target: label; property: "opacity"; to: 1; duration: 250 }
    }
}
