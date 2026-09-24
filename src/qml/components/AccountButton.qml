import QtQuick
import Qt5Compat.GraphicalEffects
import ".."
import "accounts.js" as Accounts

// The identity melo speaks as, in the title bar, switchable there. Every
// installed browser, every guest cookie profile, and no account; a signed-in
// browser shows which Google account it is, and the title bar shows that
// account's name and photo while it is the one in use.
Item {
    id: acct

    signal newProfileRequested()

    // the list and who each account is come from AccountStore, which the
    // wizard and the settings window read too, so all three agree
    readonly property var entries: AccountStore.entries
    readonly property string title: Accounts.titleOf(acct.entries)
    readonly property string photo: Accounts.photoOf(acct.entries)

    implicitHeight: Theme.ctl(20)
    implicitWidth: Math.min(Theme.ctl(170), row.implicitWidth + Theme.gap(4))

    function choose(e) { Accounts.applyChoice(e, Settings) }

    function menuRows() {
        const rows = acct.entries.map((e) => ({
            label: e.label, check: e.active, act: () => acct.choose(e),
        }))
        rows.push({ label: "New profile…", rule: true, act: () => acct.newProfileRequested() })
        return rows
    }
    // rows are rebuilt as statuses arrive, so a browser's account appears in
    // the open menu rather than on the next open
    onEntriesChanged: if (acctMenu.visible && acctMenu.owner === acct) acctMenu.actions = menuRows()

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        spacing: Theme.gap(5)
        Item {
            id: avatar
            visible: acct.photo.length > 0
            width: visible ? Theme.ctl(16) : 0
            height: Theme.ctl(16)
            anchors.verticalCenter: parent.verticalCenter
            Image {
                id: photoImg
                anchors.fill: parent
                source: acct.photo
                sourceSize: Qt.size(64, 64)
                fillMode: Image.PreserveAspectCrop
                smooth: true
                asynchronous: true
                visible: false
            }
            Rectangle { id: photoMask; anchors.fill: parent; radius: width / 2; visible: false }
            OpacityMask { anchors.fill: parent; source: photoImg; maskSource: photoMask }
        }
        InkText {
            id: nameText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(Theme.ctl(130), implicitWidth)
            elide: Text.ElideRight
            text: acct.title
            ink: "textOnTitle"
            opacity: acctMa.containsMouse ? 1 : 0.8
            Behavior on opacity { NumberAnimation { duration: 140 } }
            font { pixelSize: Theme.fs(Theme.titleFontSize); family: Theme.fontFamily }
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.ctl(8)
            size: Theme.glyph(8)
            name: "chevron"
            ink: "textOnTitle"
            opacity: acctMa.containsMouse ? 1 : 0.8
        }
    }

    MouseArea {
        id: acctMa
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            AccountStore.refresh(true)
            const win = acct.Window.window
            if (!win) return
            const p = acct.mapToItem(null, 0, acct.height + Theme.gap(4))
            acctMenu.openAt(win, p.x, p.y, acct.menuRows(), acct)
        }
    }

    DropMenu { id: acctMenu }
}
