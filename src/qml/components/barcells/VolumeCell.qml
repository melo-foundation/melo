import QtQuick
import ".."
import "../.."

MSlider {
    required property var host
    parts: "volume"
    implicitWidth: host.doc.w || 90; implicitHeight: 20
    // the volume the bar's wheel changes, so the two agree
    from: 0; to: 1; value: PlayerState.volume
    // Heard while it moves. Other sliders apply on release; a volume is
    // judged by ear, so each step of the drag is applied as it happens.
    onLiveChanged: if (dragging) Player.setVolume(live)
    onCommitted: (v) => Player.setVolume(v)
}
