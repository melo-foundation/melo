import QtQuick
import ".."
import "../.."

// elapsed, total, countdown, or the compact pair
Item {
    id: root
    required property var host
    // a lone time keeps a width, so the scrub beside it does not breathe as
    // the digits change
    implicitWidth: host.type === "time" ? label.contentWidth : Math.max(Theme.sp(36), label.contentWidth)
    implicitHeight: label.implicitHeight
    readonly property real remaining: Math.max(0, PlayerState.duration - PlayerState.position)
    InkText {
        id: label
        anchors.fill: parent
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.host.type === "elapsed" ? root.host.fmt(PlayerState.position)
            : root.host.type === "total" ? root.host.fmt(PlayerState.duration)
            : root.host.type === "countdown" ? "-" + root.host.fmt(root.remaining)
            : root.host.fmt(PlayerState.position) + (root.host.doc.sep || " / ")
              + (root.host.doc.second === "countdown" ? "-" + root.host.fmt(root.remaining)
                                                      : root.host.fmt(PlayerState.duration))
        ink: root.host.ink.length > 0 ? root.host.ink : "textSoft"
        font { pixelSize: Theme.fs(root.host.doc.size || 11); family: Theme.fontFamily; weight: Theme.weightBase }
    }
}
