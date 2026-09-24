import QtQuick
import ".."

// A push button: a word on a framed face, or on the accent when it is the one a
// dialog wants pressed. Sites give the word and the click; height, faces and press
// live here. Disabled, the faces do not light up under the pointer either, since
// that would promise a press that will not happen.
Surface {
    id: root
    property string label
    property bool accent: false        // the primary one: the accent face
    property bool active: false        // this one is ON
    property string ink: accent ? "textOnAccent" : (active ? "textOnActive" : "text")
    // Delete, reset: the label in the danger colour. `danger` is a colour
    // role, not an ink, so it binds the label's color.
    property bool danger: false
    property real fontSize: 11
    property real pad: 16              // the word's air, both sides together
    signal clicked()

    readonly property bool hovered: root.enabled && ma.containsMouse
    readonly property bool held: root.enabled && ma.pressed
    readonly property int shift: Theme.pressShift(held)

    implicitWidth: lbl.implicitWidth + pad
    implicitHeight: Theme.btnH
    radius: Theme.radiusMd
    role: accent ? Theme.faceOf("accent", hovered, held)
                 : Theme.faceOf("button", hovered, held, active)
    // the accent IS the edge; a framed one takes the border that reacts —
    // and one that is already on does not react at all
    borderWidth: accent ? 0 : 1
    borderRole: hovered && !active ? "borderStrong" : "border"

    InkText {
        id: lbl
        objectName: "btnLabel"
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root.shift
        anchors.verticalCenterOffset: root.shift
        text: root.label
        ink: root.ink
        font { pixelSize: Theme.fs(root.fontSize); family: Theme.fontFamily }
        Binding { target: lbl; property: "color"; value: Theme.danger; when: root.danger }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
