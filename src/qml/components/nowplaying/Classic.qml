import QtQuick
import ".."
import "../.."

// The plain page at rest: the cover is the screen, with the title and the
// artist under it, and nothing to read.
Item {
    id: pane
    property var np
    clip: true

    // With the words on, the cover shrinks and moves up to make room for them.
    readonly property bool words: !!(np && np.showWords && np.hasWords)
    // Only the words switch animates, through wordsT, and the geometry is read
    // off it. Easing the geometry itself would ease every resize frame, and
    // the cover would trail the edge being dragged.
    property real wordsT: words ? 1 : 0
    Behavior on wordsT { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    function lerp(a, b) { return a + (b - a) * wordsT }

    // The page it morphs FROM already has the artwork on screen at this exact
    // size, so it travels here rather than being drawn twice and cross-faded.
    // The cover keeps its place in the layout eitherway.
    property bool coverVisible: true
    property bool metaVisible: true
    readonly property real coverX: header.x + cover.x
    readonly property real coverY: header.y + cover.y
    readonly property real coverW: cover.width
    // where the title block lands, so the one travelling in can aim at it
    readonly property real metaX: header.x
    readonly property real metaY: header.y + cover.height + 14
    readonly property real metaW: header.width

    NpWords {
        np: pane.np
        x: (pane.width - width) / 2
        y: header.y + header.height + 26
        // the page's inset, plus the wider band a full-page column stands in
        width: Math.min(pane.width - GridUi.padX - 60, 620)
        height: pane.height - y - GridUi.padBottom - 14
        fontSize: 17
        align: Text.AlignHCenter
        opacity: pane.wordsT
        visible: opacity > 0.01 && height > 80
    }

    Item {
        id: header
        x: GridUi.padLeft + 10
        width: parent.width - GridUi.padX - 20
        y: pane.lerp(Math.max(GridUi.padTop + 10, (pane.height - height) / 2),
                     GridUi.padTop + 18)
        height: cover.height + 14 + meta.height

        Surface {
            id: cover
            width: pane.lerp(Math.min(pane.width - GridUi.padX - 20, pane.height * 0.5, 320),
                             Math.min(pane.width - GridUi.padX - 20, pane.height * 0.22, 170))
            height: width
            x: (header.width - width) / 2
            y: 0
            radius: Theme.radiusLg
            role: "button"
            clip: true
            visible: pane.coverVisible
            Image {
                anchors.fill: parent
                source: pane.np ? pane.np.art : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        Column {
            id: meta
            x: 0
            y: cover.height + 14
            width: header.width
            spacing: 3
            visible: pane.metaVisible

            ScrollText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: pane.np ? pane.np.title : ""
                ink: "text"
                font { pixelSize: Theme.fs(19); family: Theme.fontFamily
                       weight: Theme.weightBold }
            }
            ScrollText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: pane.np ? pane.np.channel : ""
                ink: "textDim"
                font { pixelSize: Theme.fs(14); family: Theme.fontFamily; weight: Theme.weightBase }
            }
            InkText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: !pane.np || !pane.np.vid
                text: "Nothing playing"
                ink: "textFaint"
                font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightBase }
            }
        }
    }
}
