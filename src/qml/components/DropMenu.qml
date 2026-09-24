import QtQuick
import QtQuick.Controls
import QtQuick.Window
import ".."

// A REAL dropdown: a Qt.Popup window (xdg-popup on Wayland), so it can
// extend past its parent window's edge and the compositor constrains it to
// the screen — unlike an in-window menu, which clips at the window bounds.
// Outside clicks dismiss it via the popup grab.
Window {
    id: pop
    flags: Qt.Popup | Qt.FramelessWindowHint
    color: "transparent"
    visible: false
    // The blur region is built from the window size at apply time and the height
    // settles a frame after show, so applying once would clip or lose the glass; it
    // follows the size.
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
    // As tall as its list, up to a point, then it scrolls. A menu that does
    // not fit below its anchor is flipped above it by the compositor, and a
    // very tall one lands well above the window it belongs to.
    readonly property real rowH: Theme.sp(28)
    readonly property real maxH: Math.max(rowH * 6, Screen.desktopAvailableHeight * 0.4)
    // From the count, not from the column. The column's rows are built when
    // the model is assigned and its height follows a frame later, and the
    // compositor places a popup once, with the size it has when it is mapped.
    height: Math.min(maxH, rowH * actions.length + actions.filter(a => a.rule === true).length * Theme.gap(5))
            + Theme.inset("menu", "top") + Theme.inset("menu", "bottom")

    property var actions: []

    // width follows the longest label
    TextMetrics {
        id: tm
        font.pixelSize: Theme.fs(12)
        font.family: Theme.fontFamily
    }

    // (wx, wy) are parent-window coordinates. Wayland reports parent
    // windows at 0,0 so global == window-relative there; on X11 the real
    // parent position is added.
    property double openedAt: 0
    // the head that opened it, if one did: it draws active while this shows
    property Item owner: null

    function openAt(parentWindow, wx, wy, actionList, owner_) {
        transientParent = parentWindow
        actions = actionList
        owner = owner_ === undefined ? null : owner_
        openedAt = Date.now()
        let w = 100
        for (const a of actionList) {
            tm.text = a.label
            w = Math.max(w, tm.width + 30 + (a.entry !== undefined ? Theme.ctl(16) + Theme.gap(4) : 0))
        }
        // At least as wide as the field it drops from, so a menu under a wide
        // field does not hang off its left edge. A long label still widens it
        // past a narrow field.
        width = Math.max(owner && owner.width ? Math.ceil(owner.width) : 0, Math.min(300, Math.ceil(w)))
        x = parentWindow.x + wx
        y = parentWindow.y + wy
        visible = true
        // melo's binary defines this; a test runner does not
        if (typeof MELO_FOCUS_DEBUG !== "undefined" && MELO_FOCUS_DEBUG)
            console.warn("[focus-debug] menu parent", parentWindow.x, parentWindow.y,
                        parentWindow.width + "x" + parentWindow.height, "asked", wx, wy,
                        "popup", pop.x, pop.y, pop.width + "x" + pop.height,
                        "screen", Screen.width + "x" + Screen.height)
    }
    function close() { visible = false }

    onActiveChanged: if (!active && visible) visible = false

    Surface {
        anchors.fill: parent
        radius: Theme.radiusMd
        role: "menu"
        borderWidth: 1
        borderRole: "border"

        Flickable {
            id: menuFlick
            anchors.fill: parent
            anchors.leftMargin: Theme.inset("menu", "left")
            anchors.topMargin: Theme.inset("menu", "top")
            anchors.rightMargin: Theme.inset("menu", "right")
            anchors.bottomMargin: Theme.inset("menu", "bottom")
            objectName: "menuFlick"
            clip: true
            interactive: contentHeight > height
            contentHeight: menuColumn.implicitHeight
            contentWidth: width
            // the wheel goes at the speed the settings ask for, here as
            // everywhere else — a menu long enough to scroll is still a scroll
            WheelScroll { parent: menuFlick; target: menuFlick }
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: parent.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
        Column {
            id: menuColumn
            width: parent.width

            Repeater {
                model: pop.actions
                Surface {
                    required property var modelData
                    // a row may open a group: a hairline above it
                    readonly property bool rule: modelData.rule === true
                    width: menuColumn.width
                    height: Theme.sp(28) + (rule ? Theme.gap(5) : 0)
                    Rectangle { visible: parent.rule; width: parent.width; height: 1; y: Theme.gap(2); color: Theme.border }
                    radius: Theme.radiusSm
                    role: itemMa.containsMouse ? "hover" : ""
                    EntryChip {
                        id: rowChip
                        visible: modelData.entry !== undefined
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gap(8)
                        width: visible ? Theme.ctl(16) : 0; height: Theme.ctl(16)
                        entry: modelData.entry
                    }
                    InkText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: rowChip.right
                        anchors.leftMargin: rowChip.visible ? Theme.gap(6) : Theme.gap(10)
                        anchors.right: rowCheck.left
                        anchors.rightMargin: Theme.gap(6)
                        elide: Text.ElideRight
                        text: modelData.label
                        ink: "text"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    }
                    // Marks the choice in force in a single-choice menu (the account menu's
                    // identities). Drawn, not a tick character: the theme's font may not carry one.
                    Icon {
                        id: rowCheck
                        objectName: "menuCheck"
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.gap(8)
                        visible: modelData.check === true
                        width: visible ? Theme.ctl(10) : 0
                        size: Theme.glyph(10)
                        name: "check"
                        color: itemMa.containsMouse ? Theme.text : Theme.textSoft
                    }
                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: { pop.close(); modelData.act() }
                    }
                }
            }
        }
        }
    }

    Shortcut { sequence: "Escape"; onActivated: pop.close() }
    PopupScrim { host: pop.transientParent; active: pop.visible; onDismissed: pop.close() }
}
