import QtQuick
import ".."

// A dropdown's head: the button that shows what is chosen and opens the
// list. It takes the button height, faces and press, or the input's face when
// the theme draws its selects as fields. The caller owns the list: settings,
// the bar editor and the EQ each open their own menu on the click.
Item {
    id: root
    property string label
    property string ink: "text"
    // Open while `menu` shows for this head; drives the active face.
    // DropMenu is a Window, not an Item. Both window and in-scene menus
    // expose visible/owner; constraining this to Item loses the open state.
    property QtObject menu: null
    property bool open: menu !== null && menu.visible === true && menu.owner === root
    property real pad: Theme.inset("input", "left")   // the label's left inset
    readonly property bool hovered: ma.containsMouse
    readonly property bool pressed: ma.pressed
    readonly property int shift: Theme.pressShift(ma.pressed)
    signal clicked()

    implicitWidth: lbl.implicitWidth + pad + 18
    implicitHeight: Theme.btnH

    Surface {
        objectName: "selFace"
        anchors.fill: parent
        radius: Theme.radiusMd
        role: Theme.faceOf("select", root.hovered, root.pressed, root.open)
        borderWidth: 1
        borderRole: root.hovered && !root.open ? "borderStrong" : "border"
    }
    InkText {
        id: lbl
        objectName: "selLabel"
        anchors { left: parent.left; leftMargin: root.pad + root.shift
                  right: caret.left; rightMargin: 4
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: root.shift }
        text: root.label; ink: root.ink
        elide: Text.ElideRight
        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
    }
    InkText {
        id: caret
        anchors { right: parent.right; rightMargin: 6 - root.shift
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: root.shift }
        text: "▾"; ink: "textFaint"; font { pixelSize: Theme.fs(9) }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: root.clicked() }
}
