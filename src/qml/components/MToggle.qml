import QtQuick
import QtQuick.Window
import ".."

// The app's on/off switch. Every toggle is this one, so a theme that sizes it
// sizes them all. Theme.toggleStyle "checkbox" draws it as a box with a check.
Surface {
    id: tog

    property bool checked: false
    signal toggled(bool v)

    readonly property bool box: Theme.toggleStyle === "checkbox"
    readonly property bool hovered: hit.containsMouse
    width: box ? height : Theme.ctl(Theme.toggleWidth)
    height: Theme.ctl(Theme.toggleHeight)
    // the track's corners follow the knob's: a square knob in a round track
    radius: box ? 0 : Theme.toggleKnobShape === "square" ? Theme.knobRadius("square", height)
                                                         : Theme.pill(height / 2)
    role: box ? "" : (checked ? "toggleOn" : "toggleOff")

    // A checkbox is drawn on the device grid: at 1.9 a 13px box with a 1px
    // outline is 24.7 and 1.9 device px, and its four sides come out 2/2/2/3.
    readonly property real dpr: GridUi.dpr > 1 ? GridUi.dpr
                              : Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    function dev(v) { return Math.round(v * dpr) / dpr }
    property real alignX: 0
    property real alignY: 0
    function align() {
        if (!Window.window) return
        const q = mapToItem(null, 0, 0)
        const ax = (Math.round(q.x * dpr) - q.x * dpr) / dpr, ay = (Math.round(q.y * dpr) - q.y * dpr) / dpr
        if (ax !== alignX) alignX = ax
        if (ay !== alignY) alignY = ay
    }
    Connections {
        target: tog.box && tog.visible && typeof FrameClock !== "undefined" ? FrameClock : null
        function onSyncing() { tog.align() }
    }

    Surface {
        id: face
        objectName: "checkBoxFace"
        visible: tog.box
        x: tog.alignX; y: tog.alignY
        width: tog.dev(tog.height); height: width
        radius: Math.min(width / 2, Theme.checkboxRadius * Theme.uiScale * Theme.controlScale)
        role: tog.checked ? (tog.hovered ? "checkBoxOnHover" : "checkBoxOn") : (tog.hovered ? "checkBoxHover" : "checkBox")
        borderRole: "checkBoxBorder"
        borderWidth: Theme.checkboxBorder > 0 ? Math.max(1, Math.round(Theme.checkboxBorder * tog.dpr)) / tog.dpr : 0
        // a second ring inside the outline, its width: classic's two-tone
        // sunken edge. Unset, there is none.
        Surface {
            objectName: "checkBoxInner"
            property bool set: Theme.p.checkBoxInner !== undefined
            visible: set && face.borderWidth > 0
            x: face.borderWidth; y: x
            width: face.width - 2 * x; height: width
            radius: Math.max(0, face.radius - x)
            borderRole: visible ? "checkBoxInner" : ""
            borderWidth: face.borderWidth
        }
        Icon {
            objectName: "checkMark"
            visible: tog.checked
            name: "checkBox"
            ink: "checkMark"
            size: tog.dev(face.width * 0.7)
            x: tog.dev((face.width - size) / 2); y: x
            strokeWidth: Theme.checkWeight
        }
    }
    Surface {
        // the knob sits the same distance in on all four sides, so the track's
        // height is what sizes it — a taller toggle gets a bigger knob rather
        // than a 16px one rattling in it
        readonly property real inset: Theme.ctl(2)
        visible: !tog.box
        width: Math.max(2, tog.height - inset * 2); height: width
        radius: Theme.knobRadius(Theme.toggleKnobShape, width)
        y: inset
        x: tog.checked ? tog.width - width - inset : inset
        objectName: "toggleKnob"
        role: "toggleKnob"
        Behavior on x { NumberAnimation { duration: 100 } }
    }
    MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; onClicked: tog.toggled(!tog.checked) }
}
