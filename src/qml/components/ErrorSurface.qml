import QtQuick
import ".."

// Errors, as an overlay in both windows so compact mode shows a failed stream.
// A one-off event (a failed resolve) gets a message that leaves; an ongoing state
// (backend down) must not auto-dismiss into a working-looking window.
Item {
    id: surface

    // Ongoing condition, shown until it clears. Outranks any transient.
    property string state_: ""
    // What the sidecar last refused, cleared on a timer.
    property string event_: PlayerState.error
    property string action: PlayerState.errorAction

    signal actionTriggered(string kind)

    readonly property bool showingState: state_.length > 0
    readonly property string text: showingState ? state_ : event_
    readonly property bool shown: text.length > 0

    anchors.fill: parent
    visible: shown
    z: 900

    // 500ms before a state message appears, so a sidecar that is merely still
    // starting does not flash "unavailable" on every launch.
    Timer {
        id: settle
        interval: 500
        onTriggered: card.opacity = 1
    }
    onShownChanged: {
        if (!shown) { card.opacity = 0; settle.stop(); return }
        if (showingState) settle.restart()
        else card.opacity = 1
    }

    // Transient only. A state message stays until the state clears.
    Timer {
        id: dismiss
        interval: 8000
        running: surface.shown && !surface.showingState
        onTriggered: PlayerState.error = ""
    }

    Surface {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.gap(16)
        width: Math.min(row.implicitWidth + Theme.gap(28), parent.width - Theme.gap(24))
        height: Math.max(Theme.ctl(34), row.implicitHeight + Theme.gap(14))
        radius: Theme.radiusMd
        role: "dialog"
        borderWidth: 1
        borderColor: surface.showingState ? Theme.danger : Theme.border
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        visible: opacity > 0.01

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.gap(10)

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "alert"
                size: Theme.glyph(14)
                color: surface.showingState ? Theme.danger : Theme.textSoft
            }
            InkText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, surface.width - Theme.gap(140))
                text: surface.text
                elide: Text.ElideRight
                ink: "text"
                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
            }
            // The one thing that fixes it, named. Absent when there isn't one.
            PushButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: surface.action.length > 0
                pad: Theme.gap(16)
                radius: Theme.radiusSm
                label: surface.action === "signin" ? "Sign in" : "Retry"
                onClicked: surface.actionTriggered(surface.action)
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            // A state message is not dismissible: the condition is still true.
            enabled: !surface.showingState
            onClicked: PlayerState.error = ""
            z: -1
        }
    }
}
