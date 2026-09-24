import QtQuick
import ".."

// SkeletonText's morph for values that must not marquee (durations, counts, row
// indices): the label is a plain Text. A ScrollText label would fail
// tst_searchview, which asserts every visible ScrollText in a row overflows on
// hover. Timing matches SkeletonText (180ms width, 220ms crossfade) so a row's
// bars resolve together.
Item {
    id: root
    property alias text: label.text
    property alias color: label.color
    property alias font: label.font
    property alias horizontalAlignment: label.horizontalAlignment
    property bool loading: false
    property bool shimmer: true
    property bool morph: true
    property real placeholderWidth: 30
    property real barHeight: 11
    // right-aligned columns (duration, index) pin the bar to the right edge so
    // it occupies the same pixels the value will
    property bool alignRight: false

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
    // What the value ACTUALLY measures in the current font, for a caller
    // sizing the column it sits in. Independent of root.width, so a caller
    // may bind its width to it: label.implicitWidth ignores both the elide
    // and the width it is elided against.
    readonly property real textW: label.implicitWidth
    readonly property real barOpacity: bar.opacity     // test hooks
    readonly property real barWidth: bar.width
    readonly property real labelOpacity: label.opacity

    Skeleton {
        id: bar
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: root.alignRight ? parent.right : undefined
        anchors.left: root.alignRight ? undefined : parent.left
        width: root.barW
        height: root.barHeight
        radius: Theme.squared ? 0 : 3
        shimmer: root.shimmer
        opacity: 0
        visible: opacity > 0.01
    }

    Text {
        id: label
        width: root.width
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: root.alignRight ? Text.AlignRight : Text.AlignLeft
        elide: Text.ElideRight
        opacity: 1
    }

    Component.onCompleted: if (loading) enterLoading()
    onLoadingChanged: {
        if (loading) enterLoading()
        else Qt.callLater(leaveLoading)   // next tick: arriving text measured
    }
    function enterLoading() {
        morphSeq.stop()
        fadePar.stop()
        bar.width = root.barW
        bar.opacity = 1
        label.opacity = 0
    }
    function leaveLoading() {
        if (loading) return   // flipped back before the tick
        if (morph) {
            morphSeq.toW = Math.max(1, Math.min(label.implicitWidth, root.width || label.implicitWidth))
            morphSeq.restart()
        } else {
            fadePar.restart()
        }
    }

    SequentialAnimation {
        id: morphSeq
        property real toW: 30
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
