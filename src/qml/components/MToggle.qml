import QtQuick
import ".."

// The app's on/off switch. Every toggle is this one, so a theme that sizes it
// sizes them all.
Surface {
    id: tog

    property bool checked: false
    signal toggled(bool v)

    width: Theme.ctl(Theme.toggleWidth)
    height: Theme.ctl(Theme.toggleHeight)
    radius: Theme.pill(height / 2)
    role: checked ? "toggleOn" : "toggleOff"

    Surface {
        // the knob sits the same distance in on all four sides, so the track's
        // height is what sizes it — a taller toggle gets a bigger knob rather
        // than a 16px one rattling in it
        readonly property real inset: Theme.ctl(2)
        width: Math.max(2, tog.height - inset * 2); height: width
        radius: Theme.knobRadius(Theme.toggleKnobShape, width)
        y: inset
        x: tog.checked ? tog.width - width - inset : inset
        objectName: "toggleKnob"
        role: "toggleKnob"
        Behavior on x { NumberAnimation { duration: 100 } }
    }
    MouseArea { anchors.fill: parent; onClicked: tog.toggled(!tog.checked) }
}
