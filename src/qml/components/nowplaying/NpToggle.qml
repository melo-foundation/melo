import QtQuick
import ".."
import "../.."

// Info | Lyrics, in the style the theme gives toggles: each word a
// SelectTab, and behind them the track and travelling pill a segment has.
Item {
    id: root
    property var np
    readonly property bool segmented: Theme.toggles === "segment"
    implicitWidth: row.width + (segmented ? 8 : 0)
    implicitHeight: 30

    SegmentTrack { strip: row; style: Theme.toggles }
    component Seg: SelectTab {
        property int mode: 0
        property bool dead: false      // nothing behind it — say so and refuse
        style: Theme.toggles
        active: root.np && root.np.tab === mode
        hover: segMa.containsMouse; pressed: segMa.pressed
        fontSize: 11
        weight: Theme.weightMedium
        width: implicitWidth
        height: line ? root.height : root.height - 8
        anchors.verticalCenter: parent.verticalCenter
        opacity: dead ? 0.55 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }
        MouseArea {
            id: segMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: !parent.dead
            cursorShape: Qt.PointingHandCursor
            onClicked: root.np.tab = parent.mode
        }
    }
    Row {
        id: row
        x: root.segmented ? 4 : 0
        height: parent.height
        spacing: root.segmented ? 0 : Theme.gap(2)
        Seg { id: infoTab; label: "Info"; mode: 0 }
        Seg {
            id: lyricsTab
            label: "Lyrics"
            mode: 1
            dead: root.np ? root.np.noLyrics === true : false
        }
    }
}
