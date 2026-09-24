import QtQuick
import ".."

// Context menu driven by open(x, y, actions:[{label, act}]).
// A real window (xdg-popup on Wayland) so it can extend past the app window, but
// non-grabbing (ToolTip, not Popup): a popup grab swallows the press that
// dismisses it, so right-clicking another row would take two clicks. This Item
// catches in-window outside clicks and lets them fall through; clicks outside
// the app deactivate the host window (see the Connections below).
Item {
    id: menuLayer
    anchors.fill: parent
    // NB: an explicit flag, NOT "visible: pop.visible" — a child of an
    // invisible parent reads back visible=false, which deadlocks the layer
    // closed no matter what open() sets.
    visible: false
    z: 1000

    property alias actions: menuRepeater.model
    // test hooks: menu position in host-window coordinates
    readonly property real menuX: pop.x - (menuLayer.Window.window ? menuLayer.Window.window.x : 0)
    readonly property real menuY: pop.y - (menuLayer.Window.window ? menuLayer.Window.window.y : 0)
    readonly property Item menuItem: menuBox   // tests click the popup directly

    // `hostWin` is the window the coordinates belong to. It is the layer's own
    // window everywhere except the mini player, whose bar is a SEPARATE
    // toplevel, and its coordinates against the main window would put the menu
    // a whole window away from the cursor.
    property var hostWin: null
    // the menu inset, as a dropdown's
    function pad(side) { return Theme.inset("menu", side) }
    property Item owner: null   // the head that opened it, if one did
    function open(x, y, actionList, host_, owner_) {
        const host = host_ || menuLayer.Window.window
        if (!host) return
        owner = owner_ === undefined ? null : owner_
        menuLayer.hostWin = host
        menuRepeater.model = actionList
        let w = 120
        for (const a of actionList) {
            tm.text = a.label
            // a submenu row gives up its right end to the chevron, a checked one to the tick
            w = Math.max(w, tm.width + 30 + (a.sub === true || a.check !== undefined ? 20 : 0))
        }
        pop.width = Math.min(300, Math.ceil(w))
        pop.transientParent = host
        // host-window content coords -> global (Wayland reports the host at
        // 0,0, so this is a no-op there; X11 adds the real position)
        pop.x = host.x + x
        pop.y = host.y + y
        pop.visible = true
        visible = true
    }
    signal subClosed()
    function close() {
        if (subOpen) { subOpen = false; subClosed() }
        pop.visible = false
        visible = false
    }

    MouseArea {   // in-window outside click / right-click closes
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        // let the press fall through: a right-click on ANOTHER row must
        // close this menu AND reach that row so it re-opens in one click
        onPressed: (m) => { menuLayer.close(); m.accepted = false }
    }

    TextMetrics {
        id: tm
        font.pixelSize: Theme.fs(12)
        font.family: Theme.fontFamily
    }

    // clicks outside the app can't reach the MouseArea above — but they
    // deactivate the host window (the menu itself never takes focus)
    // set while a submenu is up: it is a focus-taking popup, so the host
    // window goes inactive and the rule below would shut the menu under it
    property bool subOpen: false

    Connections {
        target: menuLayer.hostWin
        enabled: menuLayer.visible
        function onActiveChanged() {
            if (!menuLayer.hostWin.active && !menuLayer.subOpen) menuLayer.close()
        }
    }

    Window {
        id: pop
        flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
        color: "transparent"
        visible: false
        // Optional glass backing; the radius is set per call because the window blur
        // shares it with the main window's. The blur region is built from the window size
        // at apply time and the height settles a frame after show, so applying once would
        // clip or lose the glass; it follows the size.
        function applyGlass() {
            if (!pop.visible) return
            WindowCtl.setBlurRadius(Theme.radiusMd)
            WindowCtl.setBlurBehind(pop, Theme.menuBlur)
            WindowCtl.setBackgroundContrast(pop, Theme.menuBlur, Theme.glassContrast, Theme.glassSaturation)
        }
        onVisibleChanged: applyGlass()
        onWidthChanged: applyGlass()
        onHeightChanged: applyGlass()
        width: 200
        height: menuColumn.implicitHeight + menuLayer.pad("top") + menuLayer.pad("bottom")

        Surface {
            id: menuBox
            anchors.fill: parent
            radius: Theme.radiusMd
            role: "menu"   // theme's context menu opacity
            borderWidth: 1
            borderRole: "border"

            Column {
                id: menuColumn
                anchors.fill: parent
                anchors.leftMargin: menuLayer.pad("left")
                anchors.topMargin: menuLayer.pad("top")
                anchors.rightMargin: menuLayer.pad("right")
                anchors.bottomMargin: menuLayer.pad("bottom")

                Repeater {
                    id: menuRepeater
                    Surface {
                        id: itemRow
                        required property var modelData
                        // an entry carrying `sub` opens a panel beside the menu
                        // and leaves it standing, rather than acting and closing
                        readonly property bool isSub: modelData.sub === true
                        // a row may open a group: a hairline above it, as DropMenu
                        readonly property bool rule: modelData.rule === true
                        width: menuColumn.width
                        height: Theme.sp(28) + (rule ? Theme.gap(5) : 0)
                        radius: Theme.radiusSm
                        role: itemMa.containsMouse ? "hover" : ""
                        Rectangle { visible: itemRow.rule; width: parent.width; height: 1; y: Theme.gap(2); color: Theme.border }
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: itemRow.rule ? Theme.gap(5) / 2 : 0
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gap(10)
                            anchors.right: arrow.left
                            elide: Text.ElideRight
                            text: modelData.label
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        // a drawn chevron, not a character: the font may not carry one,
                        // and an indicator that sometimes fails to render is worse than none
                        Icon {
                            id: arrow
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.gap(8)
                            anchors.verticalCenterOffset: itemRow.rule ? Theme.gap(5) / 2 : 0
                            visible: itemRow.isSub || modelData.check === true
                            width: visible ? 10 : 0
                            size: Theme.glyph(10)
                            name: itemRow.isSub ? "chevron" : "check"
                            color: itemMa.containsMouse ? Theme.text : Theme.textFaint
                        }
                        // the panel hangs off the menu's right edge, level with
                        // the row it belongs to
                        function openSub() {
                            const g = itemRow.mapToItem(null, itemRow.width, 0)
                            menuLayer.subOpen = true
                            modelData.act(pop.x + g.x + 4, pop.y + g.y)
                        }
                        MouseArea {
                            id: itemMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                if (itemRow.isSub) { itemRow.openSub(); return }
                                menuLayer.close()
                                modelData.act()
                            }
                        }
                    }
                }
            }
        }

    }

    // host-side: the menu window never has focus, so this is THE Escape path
    Shortcut { sequence: "Escape"; enabled: menuLayer.visible; onActivated: menuLayer.close() }
}
