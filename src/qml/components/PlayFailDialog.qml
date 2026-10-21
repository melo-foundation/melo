import QtQuick
import ".."
import "playfail.js" as PlayFail

// The playing track could not be loaded: the error dialog (ErrorPanel) with
// the words and answers for that cause (playfail.js). Waits for one; Escape or a click
// outside dismisses it and the track stays where it is. In a host too short
// for a panel (the mini player) it is the bar size, covering the host.
Item {
    id: dlg
    anchors.fill: parent
    z: 995

    property bool shown: false
    property string cause: ""
    property string reason: ""
    // the sidecar said a newer yt-dlp would likely play it
    property bool stale: false
    // yt-dlp is on the nightly channel already: no switch to offer
    property bool nightly: typeof Settings !== "undefined" && Settings !== null && Settings.ytdlpChannel === "nightly"
    // the signed-in browsers to pick from, and a browser check in flight
    property var choices: []
    property bool busy: false
    signal answered(string action)

    readonly property var actions: PlayFail.actionsFor(cause, choices, reason, stale, nightly)
    readonly property bool compact: height < Theme.ctl(200)
    visible: shown && cause.length > 0
    onVisibleChanged: if (visible) panel.forceActiveFocus()

    function answer(action) { if (!busy || action === "skip" || action === "report" || action === "dismiss") answered(action) }

    Rectangle {
        anchors.fill: parent
        visible: !dlg.compact
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea { anchors.fill: parent; onClicked: dlg.answer("dismiss") }
    }

    ErrorPanel {
        id: panel
        objectName: "playFailPanel"
        blocking: !dlg.compact
        anchors.centerIn: parent
        width: dlg.compact ? parent.width : Math.min(Theme.ctl(400), parent.width - Theme.gap(32))
        height: dlg.compact ? parent.height : implicitHeight
        maxWidth: width
        radius: dlg.compact ? 0 : Theme.radiusLg
        borderWidth: dlg.compact ? 0 : 1
        message: PlayFail.messageFor(dlg.cause, dlg.reason, dlg.stale)
        messageName: dlg.compact ? "playFailReasonCompact" : "playFailReason"
        namePrefix: "playFail_"
        actions: dlg.actions.map((a) => ({ id: a, label: PlayFail.labelFor(a, dlg.busy),
                                           enabled: !dlg.busy || a === "skip" || a === "report" }))
        onTriggered: (id) => dlg.answer(id)
        Keys.onEscapePressed: dlg.answer("dismiss")
        Keys.onReturnPressed: if (dlg.actions.length) dlg.answer(dlg.actions[0])
        Keys.onEnterPressed: if (dlg.actions.length) dlg.answer(dlg.actions[0])
        MouseArea { anchors.fill: parent; z: -1 }   // absorb clicks behind controls
    }
}
