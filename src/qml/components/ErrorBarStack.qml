import QtQuick
import ".."

// The non-blocking errors, as bars stacked upward from where the host puts
// the stack's bottom (above the player bar). `notices`: [{ key, message,
// actions, sticky }]; a sticky one stays until its condition clears, any other
// is dismissed by a click on it. The newest sits nearest the player bar.
Column {
    id: stack
    property var notices: []
    property real maxWidth: 520
    signal triggered(string key, string id)
    signal dismissed(string key)
    spacing: Theme.gap(6)
    width: maxWidth

    Repeater {
        model: stack.notices
        delegate: ErrorPanel {
            required property var modelData
            objectName: "notice_" + modelData.key
            anchors.horizontalCenter: parent.horizontalCenter
            // one width for every bar in the stack
            width: stack.maxWidth
            height: implicitHeight
            maxWidth: stack.maxWidth
            message: modelData.message
            messageName: "noticeText_" + modelData.key
            namePrefix: "notice_" + modelData.key + "_"
            actions: modelData.actions
            onTriggered: (id) => stack.triggered(modelData.key, id)
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: modelData.sticky !== true
                onClicked: stack.dismissed(modelData.key)
            }
        }
    }
}
