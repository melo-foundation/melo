import QtQuick
import QtQuick.Window
import ".."
import "locales.js" as Locales

// SSelect with a filter box, for lists too long to scan (locales). Closed it looks
// like SSelect; open, typing filters, Enter takes the highlighted row, Up/Down
// move, Escape cancels.
// The popup reparents to the window's contentItem and positions from mapToItem,
// since settings rows sit in a clipping Flickable. DropMenu cannot host it: it
// takes a flat action list with no filter field or keyboard focus.
Rectangle {
    id: root

    property var options: []          // [{ value, label, sub }]
    // Draw each row in the family it names. For picking a typeface, the list
    // IS the preview — a column of identical labels tells you nothing about
    // what you are choosing.
    property bool previewFont: false
    property int rowHeight: Theme.sp(previewFont ? 30 : 24)
    property string value
    property string placeholder: ""
    property int popupHeight: 220
    signal picked(string v)
    readonly property bool open: popup.visible

    function labelFor(v) {
        for (const o of options) if (o.value === v) return o.label
        return v.length ? v : placeholder
    }

    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Theme.sp(150); height: head.implicitHeight
    color: "transparent"   // the head draws the face

    // for options that are expensive to gather and pointless to gather early
    signal opening()

    SelectHead {
        id: head
        anchors.fill: parent
        label: root.labelFor(root.value)
        ink: root.value.length || root.placeholder.length ? "text" : "textFaint"
        open: popup.visible
        // A click on the control while the popup is open deactivates the
        // popup, which closes it, and then lands here: without this it
        // opens again, and the control cannot be closed by the thing that
        // opened it.
        onClicked: {
            if (Date.now() - popup.closedAt < 300) return
            root.opening(); popup.open()
        }
    }

    // ---- popup ----
    // A real popup window, like DropMenu and PlaylistFlyout: menu glass is per
    // surface, and the compositor keeps it on screen rather than clamping it to the
    // app window. Focus-taking, for the field.
    Window {
        id: popup
        flags: Qt.Popup | Qt.FramelessWindowHint
        color: "transparent"
        visible: false
        width: Math.max(root.width, 220)
        height: filterBox.height + 4 + list.height

        property var model: []

        function applyGlass() {
            if (!popup.visible) return
            WindowCtl.setBlurRadius(Theme.radiusMd)
            WindowCtl.setBlurBehind(popup, Theme.menuBlur)
            WindowCtl.setBackgroundContrast(popup, Theme.menuBlur, Theme.glassContrast, Theme.glassSaturation)
        }
        onVisibleChanged: applyGlass()
        onWidthChanged: applyGlass()
        onHeightChanged: applyGlass()

        property double openedAt: 0

        function open() {
            openedAt = Date.now()
            model = root.options
            filterField.text = ""
            list.currentIndex = Math.max(0, model.findIndex(o => o.value === root.value))
            // right-aligned under the control. Window coords -> global: on
            // Wayland the host reports 0,0 and this is a no-op; on X11 it adds
            // the real position. The compositor does the rest of the fitting,
            // so a list for a low row is not clamped to the app window.
            const host = root.Window.window
            const below = root.mapToItem(null, root.width, root.height + 4)
            popup.transientParent = host
            popup.x = host.x + below.x - popup.width
            popup.y = host.y + below.y
            visible = true
            filterField.forceActiveFocus()
            list.positionViewAtIndex(list.currentIndex, ListView.Center)
        }
        property double closedAt: 0
        function close() { if (visible) closedAt = Date.now(); visible = false }
        function commit(i) {
            if (i < 0 || i >= model.length) return
            root.picked(model[i].value)
            close()
        }

        Surface {
            id: filterBox
            width: parent.width; height: Theme.sp(26)
            radius: Theme.radiusMd
            role: "menu"
            borderWidth: 1
            borderRole: "accent"
            TextInput {
                id: filterField
                anchors.fill: parent
                anchors.leftMargin: Theme.inset("input", "left")
                anchors.rightMargin: Theme.inset("input", "right")
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                clip: true
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                onTextChanged: {
                    popup.model = Locales.filter(root.options, text)
                    list.currentIndex = popup.model.length ? 0 : -1
                }
                Keys.onEscapePressed: popup.close()
                Keys.onReturnPressed: popup.commit(list.currentIndex)
                Keys.onEnterPressed: popup.commit(list.currentIndex)
                Keys.onDownPressed: if (list.currentIndex < popup.model.length - 1) list.currentIndex++
                Keys.onUpPressed: if (list.currentIndex > 0) list.currentIndex--
            }
            InkText {
                anchors { left: parent.left; leftMargin: Theme.inset("input", "left")
                          verticalCenter: parent.verticalCenter }
                visible: filterField.text.length === 0
                text: "Search"
                ink: "textFaint"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }

        Surface {
            anchors { top: filterBox.bottom; topMargin: 4 }
            width: parent.width
            height: list.height
            radius: Theme.radiusMd
            role: "menu"
            borderWidth: 1
            borderRole: "border"

            ListView {
                id: list
                width: parent.width
                height: Math.min(root.popupHeight,
                                 Math.max(root.rowHeight, popup.model.length * root.rowHeight))
                clip: true
                model: popup.model
                WheelScroll { parent: list; target: list }
                currentIndex: 0
                boundsBehavior: Flickable.StopAtBounds

                delegate: Surface {
                    width: list.width; height: root.rowHeight
                    role: index === list.currentIndex ? "selected" : ""
                    InkText {
                        anchors { left: parent.left; leftMargin: 8; right: code.left; rightMargin: 6
                                  verticalCenter: parent.verticalCenter }
                        text: modelData.label
                        ink: "text"
                        elide: Text.ElideRight
                        font { pixelSize: Theme.fs(root.previewFont ? 13 : 11)
                               family: root.previewFont && modelData.value
                                       ? modelData.value : Theme.fontFamily }
                    }
                    InkText {
                        id: code
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        text: modelData.sub || ""
                        ink: "textFaint"
                        font { pixelSize: Theme.fs(10); family: "monospace" }
                    }
                    MouseArea {
                        anchors.fill: parent; hoverEnabled: true
                        onEntered: list.currentIndex = index
                        onClicked: popup.commit(index)
                    }
                }
                InkText {
                    anchors.centerIn: parent
                    visible: popup.model.length === 0
                    text: "No matches"
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }
        }
    }

    // Two close signals, because this popup takes focus: clicking another app
    // deactivates it (the first); clicking the host moves focus without the
    // compositor telling a Qt.Popup that already has the keyboard, so the host going
    // active while the list is up is the outside click (the second).
    Connections {
        target: popup
        function onActiveChanged() { if (!popup.active) popup.close() }
    }
    PopupScrim { host: root.Window.window; active: popup.visible; onDismissed: popup.close() }

    Connections {
        target: root.Window.window
        enabled: popup.visible
        function onActiveChanged() {
            // not the press that opened it: on some compositors the host is
            // still coming back active as the popup maps
            if (root.Window.window.active && Date.now() - popup.openedAt > 250)
                popup.close()
        }
    }
}
