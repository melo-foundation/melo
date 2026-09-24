import QtQuick
import ".."

// Three 26x26 buttons (list / grid / compact).
Row {
    id: toggle
    spacing: Theme.gap(Theme.buttonGap)

    property string layout: "list"
    signal changed_(string mode)

    component LtBtn: Surface {
        id: lt
        property string mode
        property string glyph
        readonly property bool active: toggle.layout === mode
        // The active button is already a face, so only the other two take a
        // frame; a frame under the active role would draw twice.
        readonly property bool framed: Theme.toolButtons === "button" && !lt.active
        // its face's square when it has one, so buttonGap is the whole gap
        width: lt.framed || lt.active ? Theme.iconBtn : Theme.ctl(26); height: width
        radius: Theme.radiusMd
        role: lt.active || lt.framed ? Theme.faceOf("button", ma.containsMouse, ma.pressed, lt.active)
             : ma.containsMouse ? "hover" : ""
        borderWidth: lt.framed ? 1 : 0
        borderRole: ma.containsMouse && !lt.active ? "borderStrong" : "border"
        Icon {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: Theme.pressShift(ma.pressed)
            anchors.verticalCenterOffset: Theme.pressShift(ma.pressed)
            name: parent.glyph; size: Theme.glyph(14)
            ink: lt.active ? "textOnActive" : ma.containsMouse ? "text" : "textDim"
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true
                    onClicked: toggle.changed_(parent.mode) }
    }

    LtBtn { mode: "list";    glyph: "layoutList" }
    LtBtn { mode: "grid";    glyph: "layoutGrid" }
    LtBtn { mode: "compact"; glyph: "layoutCompact" }
}
