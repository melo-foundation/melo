import QtQuick
import ".."

// In-window modal replacing window.confirm / window.prompt:
//   confirmDialog(message, cb)         -> cb(true|false)
//   promptDialog(message, initial, cb) -> cb(text|null)
//   askDialog(message, okLabel, cancelLabel, checkLabel, cb) -> cb(ok, checked)
// One per window. Enter accepts, Escape / outside click cancels.
Item {
    // NOT "layer" — Item has a built-in layer property that shadows the id
    // inside any Repeater delegate, silently. See tst_themekeys.
    id: prompt
    anchors.fill: parent
    visible: false
    z: 990

    property string mode: "confirm"
    property string message
    property var cb: null
    // askDialog's extras: its own button words, and one checkbox whose state
    // comes back with the answer -- "do not ask again" and nothing else so far.
    property string okLabel: "OK"
    property string cancelLabel: "Cancel"
    property string checkLabel: ""
    property bool checkValue: false

    function confirmDialog(msg, callback) {
        mode = "confirm"; message = msg; cb = callback
        visible = true
        panel.forceActiveFocus()
    }
    function promptDialog(msg, initial, callback) {
        mode = "prompt"; message = msg; cb = callback
        input.text = initial || ""
        visible = true
        input.forceActiveFocus()
        input.selectAll()
    }
    function askDialog(msg, ok, cancel, check, callback) {
        mode = "ask"; message = msg; cb = callback
        okLabel = ok; cancelLabel = cancel; checkLabel = check; checkValue = false
        visible = true
        panel.forceActiveFocus()
    }
    function finish(result) {
        visible = false
        const f = cb; cb = null
        const checked = checkValue
        okLabel = "OK"; cancelLabel = "Cancel"; checkLabel = ""
        if (f) f(result, checked)
    }
    function accept() { finish(mode === "prompt" ? input.text : true) }
    function reject() { finish(mode === "prompt" ? null : false) }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea { anchors.fill: parent; onClicked: prompt.reject() }
    }

    Surface {
        id: panel
        anchors.centerIn: parent
        width: Math.min(380, parent.width - 40)
        height: col.implicitHeight + Theme.inset("dialog", "top") + Theme.inset("dialog", "bottom")
        radius: Theme.radiusLg
        role: "dialog"
        borderWidth: 1
        borderRole: "border"
        Keys.onReturnPressed: prompt.accept()
        Keys.onEnterPressed: prompt.accept()
        Keys.onEscapePressed: prompt.reject()
        MouseArea { anchors.fill: parent }   // absorb clicks behind controls

        Column {
            id: col
            anchors.verticalCenter: parent.verticalCenter
            // the body grows by top + bottom; an uneven pair leans it
            anchors.verticalCenterOffset: (Theme.inset("dialog", "top") - Theme.inset("dialog", "bottom")) / 2
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.rightMargin: Theme.inset("dialog", "right")
            spacing: Theme.gap(14)

            InkText {
                width: parent.width
                text: prompt.message
                ink: "text"
                wrapMode: Text.Wrap
                font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
            }

            Surface {
                visible: prompt.mode === "prompt"
                width: parent.width
                height: 28
                radius: Theme.radiusMd
                role: "input"
                borderWidth: 1
                borderRole: input.activeFocus ? "borderStrong" : "border"
                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    clip: true
                    font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
                    onAccepted: prompt.accept()
                    Keys.onEscapePressed: prompt.reject()
                }
            }

            Row {
                visible: prompt.checkLabel.length > 0
                spacing: Theme.gap(8)
                MToggle {
                    id: askAgain
                    checked: prompt.checkValue
                    onToggled: (v) => prompt.checkValue = v
                }
                InkText {
                    anchors.verticalCenter: askAgain.verticalCenter
                    text: prompt.checkLabel
                    ink: "text"
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                }
            }

            Row {
                anchors.right: parent.right
                spacing: Theme.gap(8)
                component DlgBtn: PushButton { pad: 24; fontSize: 12 }
                DlgBtn { label: prompt.cancelLabel; onClicked: prompt.reject() }
                DlgBtn { label: prompt.okLabel; accent: true; onClicked: prompt.accept() }
            }
        }
    }
}
