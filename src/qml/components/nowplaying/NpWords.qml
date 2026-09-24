import QtQuick
import ".."
import "../.."

// The words, however the style wants them: synced lines that follow the song,
// or one block when the source had no timings.
Item {
    id: root
    property var np
    property int fontSize: 18
    property int align: Text.AlignLeft
    property color activeColor: Theme.text
    property color restColor: Theme.textDim
    // Set on a full-bleed photograph: the legibility halo stops being a taste
    // knob and is always on, because the background is not ours to choose.
    property bool overArt: false
    property real gap: 14
    property bool follow: true
    // handed to both surfaces: what to do when the words have no further to go
    property var chain: null

    readonly property var lines: np ? np.lines : []
    readonly property string plain: np ? np.plain : ""
    readonly property int activeLine: np ? np.activeLine : -1

    onActiveLineChanged: if (follow && activeLine >= 0 && !list.dragging)
        list.positionViewAtIndex(activeLine, ListView.Center)

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        visible: root.lines.length > 0
        model: root.lines
        spacing: root.gap
        WheelScroll { target: list; chain: root.chain }

        delegate: Text {
            required property int index
            required property var modelData
            // -1 means the first line has not come round yet, which is not the
            // same as being far from it — the words stay legible-dim
            readonly property int away: root.activeLine < 0
                                        ? -1 : Math.abs(index - root.activeLine)
            width: list.width
            horizontalAlignment: root.align
            wrapMode: Text.Wrap
            text: modelData.text
            color: away === 0 ? root.activeColor : root.restColor
            style: root.overArt ? Theme.overArtStyle : Theme.textStyle
            styleColor: root.overArt ? Theme.overArtStyleColor : Theme.textStyleColor
            opacity: away < 0 ? 0.7
                   : away === 0 ? 1 : away === 1 ? 0.6 : away === 2 ? 0.4 : 0.25
            font { pixelSize: Theme.fs(root.fontSize); family: Theme.fontFamily
                   weight: away === 0 ? Theme.weightBold : Theme.weightBase }
            Behavior on opacity { NumberAnimation { duration: 220 } }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.np.seekTo(modelData.t)
            }
        }
    }

    Flickable {
        id: block
        anchors.fill: parent
        clip: true
        visible: root.lines.length === 0 && root.plain.length > 0
        contentHeight: blockText.implicitHeight
        WheelScroll { target: block; chain: root.chain }
        Text {
            id: blockText
            width: block.width
            horizontalAlignment: root.align
            wrapMode: Text.Wrap
            lineHeight: 1.45
            text: root.plain
            color: root.restColor
            style: root.overArt ? Theme.overArtStyle : Theme.textStyle
            styleColor: root.overArt ? Theme.overArtStyleColor : Theme.textStyleColor
            font { pixelSize: Theme.fs(root.fontSize - 3); family: Theme.fontFamily; weight: Theme.weightBase }
        }
    }
}
