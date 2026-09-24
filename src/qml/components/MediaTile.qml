import QtQuick
import ".."

// The grid tile: thumbnail, optional duration badge, then title and a line of
// meta.
Rectangle {
    id: tile

    property string title_
    property string meta_
    property string art
    property int duration: 0            // 0 hides the badge
    property bool loading: false
    property bool tipTitle: false       // full-text popup when the title is cut
    property bool selected: false       // the playing one: its own face, and no hover over it

    // callers that track which tile the pointer is on
    readonly property alias hovered: tileMa.containsMouse

    signal clicked_(real sx, real sy)
    signal menu(real sx, real sy)

    // Implicit height, not `height:`: an anchor writes height from C++ without
    // removing a QML binding, so a bound height is written twice per step, each
    // walking the tile's subtree. Anchored callers override it with nothing to fight.
    implicitHeight: GridUi.cellHFor(width + 8)   // cellHFor works from a cell, not a tile
    radius: Theme.radiusLg
    // the ground is the Surface below; a root cannot change type, so it
    // draws as a child behind everything and this stays transparent
    color: "transparent"
    clip: true
    Surface {
        anchors.fill: parent
        z: -1
        radius: Theme.radiusLg
        role: tile.selected ? "cardSelected" : tileMa.containsMouse ? "hover" : "card"
    }

    // Insets, in design units at the tile's scale: how far the picture and
    // the text sit in from the card's own edge, so a bevel there stays
    // visible. 0 is the edge.
    readonly property real unit: width / 160
    // The theme's insets, read once per theme: a drag changes the width of
    // every tile on screen every step, so a width change costs only the
    // multiply.
    readonly property real inArtL: (Theme.ts, Theme.cardInset("cardArt", "left"))
    readonly property real inArtT: (Theme.ts, Theme.cardInset("cardArt", "top"))
    readonly property real inArtR: (Theme.ts, Theme.cardInset("cardArt", "right"))
    readonly property real inTxtL: (Theme.ts, Theme.cardInset("cardText", "left"))
    readonly property real inTxtT: (Theme.ts, Theme.cardInset("cardText", "top"))
    readonly property real inTxtR: (Theme.ts, Theme.cardInset("cardText", "right"))
    readonly property real inTxtB: (Theme.ts, Theme.cardInset("cardText", "bottom"))
    Skeleton {
        id: thumb
        x: tile.inArtL * tile.unit
        y: tile.inArtT * tile.unit
        width: parent.width - x - tile.inArtR * tile.unit
        height: GridUi.dev(width * 9 / 16)
        radius: Theme.cardArtCorners === "square" ? 0 : Theme.cardArtCorners === "round" ? Theme.radiusLg
              : tile.inArtL > 0 ? Theme.radiusSm : Theme.radiusLg
        bottomRadius: tile.inArtL > 0 ? radius : 0
        shimmer: tile.loading
        // the picture covers the container once it is there, so the skeleton's
        // fill is not needed behind it — see Skeleton.needed
        needed: art.status !== Image.Ready
        loading: tile.loading
        Image {
            id: art
            anchors.fill: parent
            // Nothing is fetched for a hidden page (`visible` reads through the parent
            // chain). Once shown it stays loaded, so returning to a page neither refetches nor
            // blanks.
            property bool everShown: false
            onVisibleChanged: if (visible) everShown = true
            Component.onCompleted: if (visible) everShown = true
            // Through ThumbImageProvider, which keeps the decoded frame: Qt holds
            // unreferenced pixmaps against a hardcoded 2MB (about seven cards), so a card
            // scrolled back into view re-decoded, a fifth of a cached scroll's cycles.
            // Non-http sources (local file, data: url) go straight to Image.
            source: !(visible || everShown) ? "" : GridUi.art(tile.art)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // Decoded at half the source (see the row thumbnails). A card is
            // drawn at ~274px; decoding it at 720 fills the pixmap cache with
            // one image and re-decodes everything scrolled back to.
            sourceSize.width: GridUi.cardPx
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }
        Rectangle {   // duration badge
            visible: tile.duration > 0 && !tile.loading
            anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: Theme.gap(4)
            width: durText.implicitWidth + 8; height: 16
            radius: 2; color: Qt.rgba(0, 0, 0, 0.75)
            Text {
                id: durText
                anchors.centerIn: parent
                text: {
                    const s = Math.max(0, Math.floor(tile.duration))
                    const m = Math.floor(s / 60)
                    return m + ":" + String(s % 60).padStart(2, "0")
                }
                color: "white"
                font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
            }
        }
    }

    // The text block. Every number below is in design units (the box, the
    // type, the spacing, the skeleton bars), so the layout keeps its
    // proportions at every tile width.
    Item {
        id: textBlock
        readonly property real tscale: parent.width / 160
        // Laid out once at twice the design size and drawn by a transform: rasterising at
        // the live size re-glyphs every tile per resize frame, stepping through integer
        // sizes, and re-rasterising at rest snaps visibly. At 2x only the largest tiles
        // magnify the raster.
        readonly property real live: 2
        scale: tscale / live
        transformOrigin: Item.TopLeft
        // The text's inset is from the card's left, right and bottom; the top
        // is the picture. The block is the room under the picture less the
        // inset, and its words sit centred in it.
        x: tile.inTxtL * tile.unit
        anchors.top: thumb.bottom
        anchors.topMargin: tile.inTxtT * tile.unit
        width: (tile.width - x - tile.inTxtR * tile.unit) / tscale * live
        height: Math.max(20, (tile.height - thumb.y - thumb.height - anchors.topMargin - tile.inTxtB * tile.unit) / tscale) * live
        // title+meta as a CENTRED tight group (pinning them to opposite edges
        // opened a void between)
        Column {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 3 * textBlock.live
            width: parent.width
            spacing: Math.max(1, Math.round(1 * textBlock.live))
            SkeletonText {
                width: parent.width
                text: tile.title_
                ink: "text"
                loading: tile.loading
                tip: tile.tipTitle
                hoverSource: tileMa
                maxLines: 2; lineHeight: 0.95
                morph: false
                placeholderWidth: 108 * textBlock.live
                barHeight: 9 * textBlock.live; barOffset: -1 * textBlock.live
                font { pixelSize: Math.round(Theme.fs(10) * textBlock.live)
                       weight: Theme.weightMedium; family: Theme.fontFamily }
            }
            SkeletonText {
                width: parent.width
                text: tile.meta_
                ink: "textDim"
                loading: tile.loading
                morph: false
                placeholderWidth: 72 * textBlock.live
                barHeight: 8 * textBlock.live
                font { pixelSize: Math.round(Theme.fs(9) * textBlock.live)
                       family: Theme.fontFamily }
            }
        }
    }

    MouseArea {
        id: tileMa
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (m) => {
            if (tile.loading) return
            const p = tileMa.mapToItem(null, m.x, m.y)
            if (m.button === Qt.RightButton) tile.menu(p.x, p.y)
            else tile.clicked_(p.x, p.y)
        }
    }
}
