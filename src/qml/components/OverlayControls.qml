import QtQuick
import ".."
import "barstyles"

// Previous, play or pause, and next over a detached picture, while the pointer is on it.
Row {
    id: oc
    property bool shown: false
    spacing: Theme.gap(8)
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 200 } }
    Repeater {
        model: ["prev", "play", "next"]
        TransportButton {
            required property string modelData
            which: modelData
            size: Theme.ctl(32)
        }
    }
}
