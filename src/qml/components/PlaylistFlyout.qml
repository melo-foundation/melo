import QtQuick
import QtQuick.Controls as QQC
import ".."

// "Add to playlist" as a flyout rather than a modal: a search field, Create
// at the top, then the playlists filtered as you type. A Qt.Popup window like
// DropMenu, so it can extend past the app window and the compositor keeps it
// on screen; unlike DropMenu it takes focus, because it has a field to type in.
Window {
    id: pop
    flags: Qt.Popup | Qt.FramelessWindowHint
    color: "transparent"
    visible: false
    width: 260
    height: box.implicitHeight

    property var track: null
    property bool download: false
    property var prompt: null      // PromptDialog, for the new-playlist name
    property var rows: []

    function allRows() {
        const out = []
        for (let i = 0; i < Library.playlists.count; i++) {
            const p = Library.playlists.get(i)
            out.push({ id: p.playlistId, title: p.title, count: p.trackCount })
        }
        return out
    }
    // gx/gy are already global: the menu is its own window and hands over the
    // screen position of the row's right edge
    function openAt(parentWindow, gx, gy, t, dl) {
        track = t; download = dl
        rows = allRows()
        filterField.text = ""
        transientParent = parentWindow
        x = gx
        y = gy
        visible = true
        filterField.forceActiveFocus()
    }
    function close() { visible = false }

    function pick(playlistId) {
        close()
        Library.addTrackToPlaylist(playlistId, track)   // adds to library if missing
        if (download && !Library.isDownloaded(track.id)) Library.download(track.id)
    }
    function createNew() {
        const t = track, dl = download, typed = filterField.text.trim()
        close()
        if (!prompt) return
        // what was typed to search for a playlist is the name it was looked
        // for by, so it is the name to offer
        prompt.promptDialog("New playlist name:", typed, (name) => {
            if (!name || !name.trim()) return
            Library.addTrack(t, false)
            Library.createPlaylist(name.trim(), t.id)
            if (dl && !Library.isDownloaded(t.id)) Library.download(t.id)
        })
    }

    // same rule as the menus: the blur region follows the size
    function applyGlass() {
        if (!pop.visible) return
        WindowCtl.setBlurRadius(Theme.radiusMd)
        WindowCtl.setBlurBehind(pop, Theme.menuBlur)
        WindowCtl.setBackgroundContrast(pop, Theme.menuBlur, Theme.glassContrast, Theme.glassSaturation)
    }
    onVisibleChanged: applyGlass()
    onWidthChanged: applyGlass()
    onHeightChanged: applyGlass()

    Surface {
        id: box
        anchors.fill: parent
        radius: Theme.radiusMd
        role: "menu"
        borderWidth: 1
        borderRole: "border"
        implicitHeight: col.implicitHeight + 8

        Column {
            id: col
            x: 4; y: 4
            width: parent.width - 8
            spacing: Theme.gap(4)

            Surface {
                width: parent.width; height: Theme.sp(26)
                radius: Theme.radiusSm
                role: "input"
                borderWidth: 1
                borderRole: filterField.activeFocus ? "borderStrong" : "border"
                TextInput {
                    id: filterField
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    clip: true
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    onTextChanged: {
                        const n = text.trim().toLowerCase()
                        pop.rows = !n ? pop.allRows()
                                      : pop.allRows().filter((r) => r.title.toLowerCase().indexOf(n) !== -1)
                    }
                    Keys.onEscapePressed: pop.close()
                    Keys.onReturnPressed: pop.rows.length ? pop.pick(pop.rows[0].id) : pop.createNew()
                    Keys.onEnterPressed: pop.rows.length ? pop.pick(pop.rows[0].id) : pop.createNew()
                }
                InkText {
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    visible: filterField.text.length === 0
                    text: "Find a playlist"
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }

            Surface {   // create sits above the list, where it is reached first
                width: parent.width; height: Theme.sp(28)
                radius: Theme.radiusSm
                role: createMa.containsMouse ? "hover" : ""
                InkText {
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: "Create playlist"
                    ink: "text"
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                }
                MouseArea { id: createMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: pop.createNew() }
            }
            Rectangle { width: parent.width; height: 1; color: Theme.border }

            ListView {
                QQC.ScrollBar.vertical: MScrollBar {}
                width: parent.width
                height: Math.min(contentHeight, 240)
                clip: true
                model: pop.rows
                WheelScroll { target: parent }
                delegate: Surface {
                    required property var modelData
                    width: ListView.view.width - Theme.scrollGutter; height: Theme.sp(28)
                    radius: Theme.radiusSm
                    role: rowMa.containsMouse ? "hover" : ""
                    InkText {
                        anchors { left: parent.left; leftMargin: 8; right: cnt.left; rightMargin: 6
                                  verticalCenter: parent.verticalCenter }
                        text: modelData.title
                        elide: Text.ElideRight
                        ink: "text"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    }
                    InkText {
                        id: cnt
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        text: modelData.count
                        ink: "textFaint"
                        font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                    }
                    MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: pop.pick(modelData.id) }
                }
            }
            InkText {
                visible: pop.rows.length === 0 && filterField.text.length > 0
                x: 8
                text: "No match"
                ink: "textFaint"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }
    }
}
