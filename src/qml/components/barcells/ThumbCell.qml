import QtQuick
import ".."
import "../.."

// The artwork; the skeleton's ground shows until the image loads.
Skeleton {
    required property var host
    implicitWidth: Theme.art(host.doc.w || 48); implicitHeight: Theme.art(host.doc.h || 28)
    radius: host.doc.r !== undefined ? host.doc.r : 2
    shimmer: PlayerState.loading && !thumbImg.visible
    Image {
        id: thumbImg
        anchors.fill: parent
        source: PlayerState.trackThumbnail
        fillMode: Image.PreserveAspectCrop
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motionFast; easing.type: Theme.motionEase } }
        asynchronous: true
    }
}
