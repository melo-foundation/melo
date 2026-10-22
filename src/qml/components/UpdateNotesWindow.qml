import QtQuick
import QtQuick.Window
import ".."
import "errorui.js" as ErrorUi

// An update, start to finish: the notes of every release above the running one,
// newest first (Updater.notes), with Update, Skip this version and Later; then the
// download's progress, Restart, or what failed with Try again. Closing it is Later
// while it offers, and leaves a download running. The notes are Markdown that
// loads nothing; a link opens in the browser.
MeloWindow {
    id: unw
    heading: "Update"
    title: "melo update"
    flags: Qt.Dialog | Qt.FramelessWindowHint
    resizable: true
    width: 520
    height: Math.min(Screen.desktopAvailableHeight * 0.8, 640)
    minimumWidth: 360
    minimumHeight: 240

    readonly property var upd: typeof Updater !== "undefined" ? Updater : null
    readonly property var notes: upd ? upd.notes : []
    readonly property bool offer: upd !== null && upd.state === "available"
    readonly property string phase: upd ? upd.state : ""

    function open() {
        notesFlick.contentY = 0
        openWindow()
        raise()
        requestActivate()
    }
    function answer(what) {
        if (!upd) return
        if (what === "update") { upd.update(); return }   // the progress shows here
        if (what === "retry") { upd.retry(); return }
        if (what === "restart") upd.restart()
        else if (what === "skip") upd.skip()
        else if (what === "later") upd.later()
        visible = false
    }
    onCloseRequested: if (offer && upd) upd.later()
    // the release went away (skipped elsewhere, or a newer check found nothing)
    onOfferChanged: if (!offer && upd && upd.state === "" && visible) visible = false

    Item {
        parent: unw.body
        anchors.fill: parent

        Flickable {
            id: notesFlick
            objectName: "updateNotesFlick"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            anchors.topMargin: Theme.inset("dialog", "top")
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.rightMargin: Theme.inset("dialog", "right")
            anchors.bottomMargin: Theme.gap(14)
            contentHeight: sections.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: sections
                width: notesFlick.width
                spacing: Theme.gap(18)
                Repeater {
                    model: unw.notes
                    delegate: Column {
                        id: section
                        required property var modelData
                        required property int index
                        objectName: "notesSection_" + index
                        width: sections.width
                        spacing: Theme.gap(4)
                        InkText {
                            objectName: "notesHeading_" + section.index
                            text: section.modelData.label
                            ink: "text"
                            font { pixelSize: Theme.fs(15); weight: Font.DemiBold; family: Theme.fontFamily }
                        }
                        InkText {
                            visible: text.length > 0
                            text: section.modelData.date
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        Text {
                            objectName: "notesBody_" + section.index
                            width: parent.width
                            topPadding: Theme.gap(4)
                            text: section.modelData.body
                            textFormat: Text.MarkdownText
                            wrapMode: Text.Wrap
                            color: Theme.text
                            linkColor: Theme.accent
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            onLinkActivated: (link) => { if (/^https?:\/\//.test(link)) Qt.openUrlExternally(link) }
                            HoverHandler { cursorShape: parent.hoveredLink.length ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        }
                    }
                }
            }
        }

        InkText {
            id: status
            objectName: "updateStatus"
            anchors.left: parent.left
            anchors.right: footer.left
            anchors.rightMargin: Theme.gap(12)
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.verticalCenter: footer.verticalCenter
            readonly property real mb: 1024 * 1024
            text: unw.phase === "downloading"
                  ? (unw.upd.total > 0 ? (unw.upd.fetched / mb).toFixed(1) + " / " + (unw.upd.total / mb).toFixed(1) + " MB"
                                       : "Downloading…")
                  : unw.phase === "failed" ? unw.upd.error : ""
            ink: unw.phase === "failed" ? "text" : "textDim"
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
        }

        Row {
            id: footer
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: Theme.inset("dialog", "right")
            anchors.bottomMargin: Theme.inset("dialog", "bottom")
            spacing: Theme.gap(8)
            component NotesBtn: PushButton { pad: 24; fontSize: 12 }
            NotesBtn {
                objectName: "updateSkip"
                visible: unw.offer
                label: "Skip this version"
                onClicked: unw.answer("skip")
            }
            NotesBtn {
                objectName: "updateLater"
                visible: unw.offer
                label: "Later"
                onClicked: unw.answer("later")
            }
            NotesBtn {
                objectName: "updateMain"
                visible: unw.upd !== null && ((unw.offer && unw.upd.canUpdate) || unw.phase === "ready"
                                              || unw.phase === "failed")
                label: unw.phase === "ready" ? "Restart" : unw.phase === "failed" ? "Try again" : "Update"
                accent: true
                // as the error bars' main button: words that read on any accent
                labelColor: ErrorUi.inkOn(Theme.accent)
                onClicked: unw.answer(unw.phase === "ready" ? "restart" : unw.phase === "failed" ? "retry" : "update")
            }
        }
    }
}
