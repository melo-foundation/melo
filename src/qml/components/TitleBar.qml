import QtQuick
import ".."

// Custom draggable title bar: app name left; search, settings, pin, min/max/close right.
Rectangle {
    id: titleBar
    height: Theme.titleBarH
    // Transparent, with the ground drawn by Surface behind everything else —
    // that is what lets a theme make the header a blend mode rather than a
    // colour. See Theme.blendOf.
    color: "transparent"
    // the most its top corners may round: the window's, or what a frame leaves
    property real radiusCap: Theme.windowRadius
    // What the window's shape eats into this bar, per end: a title bar in a
    // window cut at its corners moves its words and its buttons clear of the
    // cut instead of letting it take them
    property real cutLeft: 0
    property real cutRight: 0
    topLeftRadius: Math.min(radiusCap, height / 2)
    topRightRadius: Math.min(radiusCap, height / 2)

    // The window's ground (its colour with the background composited), which
    // adaptive chrome samples in place of the framebuffer. The background layer
    // alone would invert what is under the window, and with no background set that
    // is transparent black, which inverts to white.
    property Item backdrop: null
    // its own surface, unless a surface shared with the rows below is drawn
    property bool ground: true

    Surface {
        anchors.fill: parent
        z: -1
        visible: titleBar.ground
        role: "title"
        backdrop: titleBar.backdrop
        // TOP corners only: a plain radius rounds all four and draws a second
        // curved edge across the bottom of the header. No more than half the
        // bar's height, which is all a corner can be.
        topLeftRadius: Math.min(titleBar.radiusCap, height / 2)
        topRightRadius: Math.min(titleBar.radiusCap, height / 2)
    }

    signal searchToggle()
    signal settingsToggle()
    signal pinToggle()
    signal dragStarted()
    signal dragReleased()   // release seen = no compositor grab = no real move

    property Window win: Window.window
    property bool pinned: false
    // Only the main window carries the account control; the settings, eq and
    // mini title bars use the same component and must not grow one.
    property bool showAccount: false
    signal newProfileRequested()
    property bool searchActive: false     // search bar shown
    property bool settingsActive: false   // settings window open

    MouseArea {   // drag anywhere not on a button
        id: dragArea
        anchors.fill: parent
        // The move starts on movement, not on press: startSystemMove() hands the
        // pointer to KWin, which reads a press-and-hold on a title bar as its own, so
        // the second click of a double-click would maximise the window.
        property point origin
        property bool moving: false
        property double pressedAt: 0
        function stamp() { return new Date().toISOString().substr(11, 12) }
        onPressed: (m) => {
            dragArea.origin = Qt.point(m.x, m.y); dragArea.moving = false
            dragArea.pressedAt = Date.now()
            if (typeof MELO_FOCUS_DEBUG !== "undefined" && MELO_FOCUS_DEBUG)
                console.warn(stamp() + " [drag] press on the title bar: window.active="
                             + (titleBar.win ? titleBar.win.active : "?"))
        }
        onPositionChanged: (m) => {
            if (dragArea.moving || !pressed) return
            if (Math.abs(m.x - dragArea.origin.x) < 4
                && Math.abs(m.y - dragArea.origin.y) < 4) return
            dragArea.moving = true
            if (typeof MELO_FOCUS_DEBUG !== "undefined" && MELO_FOCUS_DEBUG)
                console.warn(dragArea.stamp() + " [drag] startSystemMove "
                             + Math.round(Date.now() - dragArea.pressedAt) + "ms after the press, active="
                             + (titleBar.win ? titleBar.win.active : "?"))
            titleBar.dragStarted()
            titleBar.win.startSystemMove()
        }
        onReleased: {
            if (dragArea.moving) titleBar.dragReleased()
            dragArea.moving = false
        }
        onDoubleClicked: {
            if (typeof CommandMap !== "undefined" && CommandMap)
                CommandMap.invokeGesture("titleBar.doubleClick")
        }
    }

    InkText {
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
        anchors.left: parent.left
        anchors.leftMargin: Theme.inset("title", "left") + titleBar.cutLeft
        text: "melo"
        ink: "textOnTitle"
        font { pixelSize: Theme.fs(Theme.titleFontSize); family: Theme.fontFamily; weight: Theme.titleWeight }
    }

    Row {
        anchors.right: parent.right
        // On whole pixels: centring a button in a bar whose height differs
        // from it by an odd number puts the faces and their glyphs on a half
        // pixel, which softens a pixel-drawn glyph
        y: Math.round((parent.height - height + Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2)
        anchors.rightMargin: Theme.inset("title", "right") + titleBar.cutRight
        spacing: Theme.gap(Theme.buttonGap)

        component TbBtn: Item {
            id: tb
            property string glyph
            property bool active: false
            signal clicked()
            // As wide as its face when it has one, so the gap between two is
            // the theme's buttonGap and nothing else; bare, the 26 hit box
            width: Theme.titleButtons === "button" ? Theme.titleBtn : Theme.ctl(26)
            height: Theme.titleButtons === "button" && Number(Theme.ts.titleButtonSize) > 0 ? Theme.titleBtn : Theme.ctl(20)

            // The window is frameless, so these ARE the window controls —
            // there is no system titlebar behind them to fall back on. Without
            // a role and a name, a screen-reader user could not close melo.
            property string a11yName: glyph === "minimize" ? "Minimise"
                                    : glyph === "maximize" ? "Maximise"
                                    : glyph === "restore" ? "Restore"
                                    : glyph === "close" ? "Close"
                                    : glyph === "pin" ? "Always on top"
                                    : glyph === "search" ? "Search"
                                    : glyph === "settings" ? "Settings" : glyph
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: tb.a11yName
            Accessible.checkable: tb.glyph === "pin"
            Accessible.checked: tb.active
            Accessible.onPressAction: tb.clicked()
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Space || e.key === Qt.Key_Return
                    || e.key === Qt.Key_Enter) { tb.clicked(); e.accepted = true }
            }
            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusSm
                color: "transparent"
                border.color: Theme.accent
                border.width: 2
                visible: tb.activeFocus
            }

            IconButton {
                objectName: "titleButton"
                anchors.centerIn: parent
                name: tb.glyph; size: Theme.glyph(13)
                // on: the words' ink on an active face, the highlight alone when bare
                ink: tb.active ? (Theme.titleButtons === "button" ? "titleGlyphActive" : "highlight")
                   : tb.glyph === "close" ? (ma.containsMouse ? "closeHover" : "close")
                   : (ma.containsMouse ? "titleGlyphHover" : "titleGlyph")
                face: tb.glyph === "close" ? "close" : "title"
                framed: Theme.titleButtons === "button"
                active: tb.active
                hovered: ma.containsMouse
                pressed: ma.pressed
                // the button's own box: the bar is 24 high, so a ctl(26)
                // square face would not fit in it
                frameWidth: Theme.titleBtn; frameHeight: Theme.titleBtnH
            }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() }
        }

        // Plugin buttons come FIRST in the row, so melo's own search / settings
        // / pin stay by the window corner. The row grows leftward into the
        // title, which elides.
        Repeater {
            model: {
                if (typeof BarButtons === "undefined" || !BarButtons) return []
                const dep = BarButtons.generation
                return BarButtons.forBar("title")
            }
            delegate: Item {
                required property var modelData
                width: Theme.ctl(26); height: Theme.ctl(20)
                Image {
                    anchors.centerIn: parent
                    width: Theme.ctl(14); height: Theme.ctl(14)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    source: modelData.icon
                    opacity: tbPluginMa.containsMouse ? 1 : 0.7
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }
                MouseArea {
                    id: tbPluginMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: CommandMap.invoke(modelData.command)
                }
            }
        }
        AccountButton {
            visible: titleBar.showAccount
            width: visible ? implicitWidth : 0
            anchors.verticalCenter: parent.verticalCenter
            onNewProfileRequested: titleBar.newProfileRequested()
        }
        TbBtn { glyph: "search"; active: titleBar.searchActive; onClicked: titleBar.searchToggle() }
        TbBtn { glyph: "settings"; active: titleBar.settingsActive; onClicked: titleBar.settingsToggle() }
        TbBtn {
            glyph: "pin"
            active: titleBar.pinned
            onClicked: titleBar.pinToggle()   // Wayland: flags are a no-op; KWin keepAbove
        }
        TbBtn { glyph: "minimize"; onClicked: titleBar.win.showMinimized() }
        TbBtn {
            glyph: titleBar.win && titleBar.win.visibility === Window.Maximized
                   ? "restore" : "maximize"
            onClicked: titleBar.win.visibility === Window.Maximized
                       ? titleBar.win.showNormal() : titleBar.win.showMaximized()
        }
        TbBtn { glyph: "close"; onClicked: titleBar.win.close() }
    }
}
