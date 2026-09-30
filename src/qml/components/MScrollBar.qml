import QtQuick
import QtQuick.Controls as QQC
import ".."

// The app's scrollbar. It sits at the right edge of its parent, beside the
// scroller and outside its clip, over the scroller's height:
//   ListView { id: list; QQC.ScrollBar.vertical: bar }
//   MScrollBar { id: bar; scroller: list }
// `edge` names a sibling to sit at instead of the parent's edge. The scroller
// must be a sibling, or `y` is set at the site. Qt lays out an attached bar
// only when its parent is the Flickable, so this one places itself.
// As a bar it is the `scrollbar` role: thin, no track, fading when idle. As a
// slider (Theme.scrollbars) it takes the slider's rail, knob and shape and never
// fades, since a fading rail looks broken.
QQC.ScrollBar {
    id: sb
    property Flickable scroller: null
    property Item edge: parent
    x: {
        if (!edge) return 0
        const left = edge === parent ? 0 : edge.x
        return mirrored ? left : left + edge.width - width
    }
    y: scroller ? scroller.y : 0
    height: scroller ? scroller.height : implicitHeight
    // AsNeeded: hidden while the content fits, rail and all
    visible: (!scroller || scroller.visible) && policy !== QQC.ScrollBar.AlwaysOff
             && (policy === QQC.ScrollBar.AlwaysOn || size < 1)
    readonly property bool slider: Theme.scrollbars === "slider"
    // As a slider: the rail at the track height, the thumb at the knob size,
    // the wider setting the thickness and the narrower centred in it. A theme
    // scrollbarWidth overrides both, so a wide scrollbar can coexist with a
    // small thumb on the volume rail.
    readonly property real own: Theme.ctl(Theme.scrollbarWidth)
    readonly property real rail: own > 0 ? own : slider ? Theme.ctl(Theme.sliderTrackHeight) : Theme.ctl(4)
    readonly property real knob: own > 0 ? own : slider ? Theme.ctl(Theme.sliderKnobSize) : Theme.ctl(4)
    readonly property real thick: Math.max(rail, knob)
    policy: QQC.ScrollBar.AsNeeded
    minimumSize: 0.08
    // the rail and thumb sit inside the theme's scrollbar inset: right from
    // the edge (negative runs past it), top and bottom from the scroller's,
    // left the room kept from the content
    leftPadding: Theme.inset("scrollbar", "left"); rightPadding: Theme.inset("scrollbar", "right")
    topPadding: Theme.inset("scrollbar", "top"); bottomPadding: Theme.inset("scrollbar", "bottom")
    implicitWidth: thick + leftPadding + rightPadding
    implicitHeight: thick + topPadding + bottomPadding
    // the rail is the thumb's run, inside the paddings, because a control's
    // background spans the paddings too
    background: Surface {
        objectName: "scrollRail"
        visible: sb.slider
        x: sb.leftPadding + (sb.vertical ? (sb.availableWidth - sb.rail) / 2 : 0)
        y: sb.topPadding + (sb.vertical ? 0 : (sb.availableHeight - sb.rail) / 2)
        width: sb.vertical ? sb.rail : sb.availableWidth
        height: sb.vertical ? sb.availableHeight : sb.rail
        radius: Theme.trackRadius(Theme.sliderTrackShape, Math.min(width, height))
        role: "scrollbarTrack"
    }
    // the bar is outside the scroller, so the wheel over it is sent on
    WheelScroll { parent: sb; target: sb.scroller; enabled: sb.scroller !== null }
    // The thumb is a child of the content item: a control stretches its
    // content item between the paddings, to the wider of rail and knob, which
    // would draw a narrow knob at the rail's width. The child is the knob's
    // own size, centred.
    contentItem: Item {
        implicitWidth: sb.thick
        implicitHeight: sb.thick
        Surface {
            objectName: "scrollThumb"
            x: sb.vertical ? (parent.width - width) / 2 : 0
            y: sb.vertical ? 0 : (parent.height - height) / 2
            width: sb.vertical ? sb.knob : parent.width
            height: sb.vertical ? parent.height : sb.knob
            radius: sb.slider ? Theme.knobRadius(Theme.sliderKnobShape, Math.min(width, height)) : Theme.pill(Math.min(width, height) / 2)
            role: sb.slider ? "scrollbarThumb" : (sb.pressed ? "accent" : "scrollbar")
            opacity: sb.slider || sb.active || sb.hovered ? 1 : 0.35
            Behavior on opacity { NumberAnimation { duration: 160 } }
            // Ridges, when the theme asks for them: three lines across the
            // thumb's middle, hidden once the thumb is too short to hold them
            // clear of its ends.
            Column {
                anchors.centerIn: parent
                spacing: Math.max(1, Math.round(Theme.ctl(2)))
                visible: Theme.scrollbarGrip === "lines"
                         && (sb.vertical ? parent.height : parent.width) > Theme.ctl(24)
                Repeater {
                    model: 3
                    Rectangle {
                        width: sb.vertical ? Math.round(parent.parent.width * 0.5) : 1
                        height: sb.vertical ? 1 : Math.round(parent.parent.height * 0.5)
                        color: Theme.control
                        opacity: 0.55
                    }
                }
            }
        }
    }
}
