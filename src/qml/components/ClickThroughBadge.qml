import QtQuick
import ".."

// While click-through is on, the window's one spot that still takes the
// pointer: a lock that shows on hover and turns the mode off. Theme.lockStyle
// is its look: the glyph alone, a title-bar button, a pill or a tab.
Item {
    id: badge
    signal released()
    readonly property string look: Theme.lockStyle
    width: look === "button" ? Theme.titleBtn : look === "pill" ? Theme.ctl(30)
         : look === "tab" ? Theme.ctl(44) : Theme.ctl(22)
    height: look === "button" ? Theme.titleBtnH : look === "pill" ? Theme.ctl(30)
          : look === "tab" ? Theme.ctl(18) : Theme.ctl(22)
    HoverHandler { id: hover }
    TapHandler { onTapped: badge.released() }

    Item {
        anchors.fill: parent
        opacity: hover.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Icon {
            visible: badge.look === "glyph"
            anchors.centerIn: parent
            name: "lock"; size: Theme.glyph(14); ink: "textDim"
        }
        IconButton {   // the window buttons' face, size and ink
            visible: badge.look === "button"
            anchors.centerIn: parent
            name: "lock"; size: Theme.glyph(13)
            ink: "titleGlyphHover"
            face: "title"
            framed: Theme.titleButtons === "button"
            hovered: true
            frameWidth: Theme.titleBtn; frameHeight: Theme.titleBtnH
        }
        Rectangle {    // the visualizer gear's pill, or a tab off the top edge
            visible: badge.look === "pill" || badge.look === "tab"
            anchors.fill: parent
            radius: Theme.pill(height / 2)
            color: Qt.rgba(0, 0, 0, 0.35)
            Icon { anchors.centerIn: parent; name: "lock"
                   size: Theme.glyph(badge.look === "tab" ? 12 : 16); ink: "text" }
        }
    }
}
