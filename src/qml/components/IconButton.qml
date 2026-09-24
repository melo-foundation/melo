import QtQuick
import ".."

// An icon, bare or on a button face, per Theme.titleButtons / toolButtons /
// transportButtons. Bare, the item is the icon's size; framed, it grows to the
// face with the icon centred, so every site anchors it at a centre.
Item {
    id: root
    property string name
    property real size: Theme.glyph(14)    // the icon's, not the face's
    property string ink: ""
    property color color: ink.length > 0 ? Theme[ink] : "#aaaaaa"
    property real strokeWidth: 2
    property bool framed: false
    property string face: "button"   // the face's kind for Theme.faceOf: a close button has its own
    property bool hovered: false
    // held: the face is `buttonPress` and, when the theme sinks, the glyph
    // moves with it — the caller hands its MouseArea's `pressed` in
    property bool pressed: false
    // ON: the pinned pin, the open queue. Framed, the face is buttonActive
    // and the caller inks the glyph textOnActive; bare, there is no face to
    // be active and the glyph alone says it, in the highlight ink.
    property bool active: false
    // the face: a square control, unless the site has less room (the title
    // bar is 24 high) or sizes its buttons itself (the transport)
    property real frameWidth: Theme.iconBtn
    property real frameHeight: frameWidth

    implicitWidth: framed ? frameWidth : size
    implicitHeight: framed ? frameHeight : size

    Surface {
        objectName: "iconFace"
        anchors.fill: parent
        visible: root.framed
        radius: Theme.radiusMd
        role: Theme.faceOf(root.face, root.hovered, root.pressed, root.active)
        borderWidth: 1
        // the title bar's buttons have edges of their own, which follow the
        // border until a theme sets them
        borderRole: root.face === "title" || root.face === "close"
                    ? (root.hovered && !root.active ? "titleButtonBorderHover" : "titleButtonBorder")
                    : root.hovered && !root.active ? "borderStrong" : "border"
    }
    Icon {
        objectName: "iconGlyph"
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: Theme.pressShift(root.pressed)
        anchors.verticalCenterOffset: Theme.pressShift(root.pressed)
        name: root.name; size: root.size; strokeWidth: root.strokeWidth
        ink: root.ink; color: root.color
    }
}
