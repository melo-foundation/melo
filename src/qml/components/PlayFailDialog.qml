import QtQuick
import ".."
import "playfail.js" as PlayFail

// The playing track could not be loaded: its reason and the answers for that
// cause (playfail.js). Waits for one; Escape or a click outside dismisses it
// and the track stays where it is. In a host too short for a panel (the mini
// player) it covers the host as one row.
Item {
    id: dlg
    anchors.fill: parent
    z: 995

    property bool shown: false
    property string cause: ""
    property string reason: ""
    // the signed-in browsers to pick from, and a browser check in flight
    property var choices: []
    property bool busy: false
    signal answered(string action)

    readonly property var actions: PlayFail.actionsFor(cause, choices)
    readonly property bool compact: height < Theme.ctl(200)
    visible: shown && cause.length > 0
    onVisibleChanged: if (visible) panel.forceActiveFocus()

    function answer(action) { if (!busy || action === "skip" || action === "dismiss") answered(action) }

    Rectangle {
        anchors.fill: parent
        visible: !dlg.compact
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea { anchors.fill: parent; onClicked: dlg.answer("dismiss") }
    }

    Surface {
        id: panel
        objectName: "playFailPanel"
        anchors.centerIn: parent
        width: dlg.compact ? parent.width : Math.min(Theme.ctl(400), parent.width - Theme.gap(32))
        height: dlg.compact ? parent.height
              : col.implicitHeight + Theme.inset("dialog", "top") + Theme.inset("dialog", "bottom")
        radius: dlg.compact ? 0 : Theme.radiusLg
        role: "dialog"
        borderWidth: dlg.compact ? 0 : 1
        borderRole: "border"
        Keys.onEscapePressed: dlg.answer("dismiss")
        Keys.onReturnPressed: if (dlg.actions.length) dlg.answer(dlg.actions[0])
        Keys.onEnterPressed: if (dlg.actions.length) dlg.answer(dlg.actions[0])
        MouseArea { anchors.fill: parent }   // absorb clicks behind controls

        Column {
            id: col
            visible: !dlg.compact
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("dialog", "top") - Theme.inset("dialog", "bottom")) / 2
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.rightMargin: Theme.inset("dialog", "right")
            spacing: Theme.gap(10)

            InkText {
                width: parent.width
                text: "Can't play this track"
                ink: "text"
                font { pixelSize: Theme.fs(14); family: Theme.fontFamily; bold: true }
            }
            InkText {
                objectName: "playFailReason"
                width: parent.width
                text: dlg.reason
                ink: "textDim"
                wrapMode: Text.Wrap
                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
            }
            Item { width: 1; height: Theme.gap(4) }
            Flow {
                width: parent.width
                layoutDirection: Qt.RightToLeft
                spacing: Theme.gap(8)
                Repeater {
                    model: dlg.compact ? [] : dlg.actions
                    delegate: PushButton {
                        required property string modelData
                        required property int index
                        objectName: "playFail_" + modelData
                        label: PlayFail.labelFor(modelData, dlg.busy)
                        enabled: !dlg.busy || modelData === "skip"
                        accent: index === 0
                        pad: 24; fontSize: 12
                        onClicked: dlg.answer(modelData)
                    }
                }
            }
        }

        // the mini player's one row: what failed on the left, the answers on the right
        Item {
            visible: dlg.compact
            anchors.fill: parent
            anchors.leftMargin: Theme.gap(12); anchors.rightMargin: Theme.gap(10)
            Column {
                anchors.left: parent.left
                anchors.right: buttons.left
                anchors.rightMargin: Theme.gap(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap(2)
                InkText {
                    width: parent.width
                    text: "Can't play this track"
                    elide: Text.ElideRight
                    ink: "text"
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily; bold: true }
                }
                InkText {
                    objectName: "playFailReasonCompact"
                    width: parent.width
                    text: dlg.reason
                    elide: Text.ElideRight
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap(6)
                Repeater {
                    model: dlg.compact ? dlg.actions : []
                    delegate: PushButton {
                        required property string modelData
                        required property int index
                        objectName: "playFail_" + modelData
                        label: PlayFail.labelFor(modelData, dlg.busy)
                        enabled: !dlg.busy || modelData === "skip"
                        accent: index === 0
                        pad: 18; fontSize: 11
                        onClicked: dlg.answer(modelData)
                    }
                }
            }
        }
    }
}
