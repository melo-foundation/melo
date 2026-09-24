import QtQuick
import ".."
import "../.."

// The artist on its own, a skeleton bar while there is no track.
SkeletonText {
    required property var host
    implicitWidth: 120; implicitHeight: Theme.sp(14)
    loading: !PlayerState.hasTrack
    shimmer: PlayerState.loading
    placeholderWidth: 80; barHeight: 9
    text: PlayerState.hasTrack ? PlayerState.trackChannel : ""
    ink: "textDim"
    font { pixelSize: Theme.fs(host.doc.size || 11); family: Theme.fontFamily; weight: Theme.weightBase }
}
