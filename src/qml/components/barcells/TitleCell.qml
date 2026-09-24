import QtQuick
import ".."
import "../.."

// Two lines: title over artist, skeleton bars while there is no track.
// One line: the title, the artist inline after a dot.
Item {
    id: root
    required property var host
    // Whether it stands in for a title it does not have. A bar on a card is
    // worth a placeholder; a bar on a black readout strip is a grey slab
    // sitting in the middle of it, so a document may say no and get an empty
    // strip until there is something to name. `skeleton` defaults to true.
    readonly property bool bars: root.host.doc.skeleton !== false
    implicitWidth: 200
    implicitHeight: host.doc.lines === 1 ? Theme.sp(16) : metaCol.implicitHeight

    Column {
        id: metaCol
        visible: root.host.doc.lines !== 1
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap(2)
        SkeletonText {
            width: parent.width
            height: Theme.sp(14)
            loading: root.bars && !PlayerState.hasTrack
            shimmer: root.bars && PlayerState.loading
            placeholderWidth: 120; barHeight: 11; barAlign: "top"
            text: PlayerState.hasTrack ? PlayerState.trackTitle : ""
            ink: root.host.ink.length > 0 ? root.host.ink : "text"
            font { pixelSize: Theme.fs(root.host.doc.size || 13); weight: Theme.weightBold; family: Theme.fontFamily }
        }
        SkeletonText {
            visible: root.host.doc.artist !== "none"
            width: parent.width
            height: Theme.sp(12)
            loading: root.bars && !PlayerState.hasTrack
            shimmer: root.bars && PlayerState.loading
            placeholderWidth: 80; barHeight: 9; barAlign: "bottom"
            text: PlayerState.trackChannel
            ink: root.host.ink.length > 0 ? root.host.ink : "textDim"
            font { pixelSize: Theme.fs(11); family: Theme.fontFamily; weight: Theme.weightBase }
        }
    }
    SkeletonText {
        visible: root.host.doc.lines === 1
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        loading: root.bars && !PlayerState.hasTrack
        shimmer: root.bars && PlayerState.loading
        placeholderWidth: 140; barHeight: 10
        text: !PlayerState.hasTrack ? ""
            : PlayerState.trackTitle + (root.host.doc.artist !== "none" && PlayerState.trackChannel.length > 0
                                        ? "  ·  " + PlayerState.trackChannel : "")
        ink: root.host.ink.length > 0 ? root.host.ink : "text"
        font { pixelSize: Theme.fs(root.host.doc.size || 12); weight: Theme.weightMedium; family: Theme.fontFamily }
    }
}
