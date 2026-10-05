import QtQuick
import "."
import ".."

// Visualizer | Video, in the style the theme gives toggles. Reports a pick;
// the owner saves it and sets `video`.
Item {
    id: root
    property bool video: false
    signal picked(bool video)
    readonly property bool segmented: Theme.toggles === "segment"
    // the segment track draws this far around the strip, on every side
    readonly property real pad: segmented ? Theme.tabTrackPad : 0
    implicitWidth: row.width + pad * 2
    implicitHeight: 30 + pad * 2

    SegmentTrack { strip: row; style: Theme.toggles }
    component Seg: SelectTab {
        property bool isVideo: false
        style: Theme.toggles
        active: root.video === isVideo
        hover: segMa.containsMouse; pressed: segMa.pressed
        fontSize: 11
        weight: Theme.weightMedium
        width: implicitWidth
        height: line ? row.height : row.height - 8
        anchors.verticalCenter: parent.verticalCenter
        MouseArea {
            id: segMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.picked(parent.isVideo)
        }
    }
    Row {
        id: row
        x: root.pad
        y: root.pad
        height: 30
        spacing: root.segmented ? 0 : Theme.gap(2)
        Seg { objectName: "seg:visualizer"; label: "Visualizer"; isVideo: false }
        Seg { objectName: "seg:video"; label: "Video"; isVideo: true }
    }
}
