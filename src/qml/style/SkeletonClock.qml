pragma Singleton
import QtQuick

// One sweep and one breath for every placeholder, so rows that appear at
// different moments move together. Runs while a placeholder counts itself in.
QtObject {
    id: clock
    property int sweepers: 0
    property int pulsers: 0
    property real sheen: -0.3
    property real breath: 1
    readonly property NumberAnimation sweep: NumberAnimation {
        target: clock; property: "sheen"
        running: clock.sweepers > 0
        loops: Animation.Infinite
        from: -0.3; to: 1.3
        duration: 1500
        easing.type: Easing.InOutQuad
    }
    readonly property SequentialAnimation pulse: SequentialAnimation {
        running: clock.pulsers > 0
        loops: Animation.Infinite
        NumberAnimation { target: clock; property: "breath"; from: 1; to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { target: clock; property: "breath"; from: 0.45; to: 1; duration: 700; easing.type: Easing.InOutQuad }
        // a pulse that stops mid-breath leaves the grounds dim
        onRunningChanged: if (!running) clock.breath = 1
    }
}
