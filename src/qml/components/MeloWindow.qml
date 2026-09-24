import QtQuick
import QtQuick.Window
import ".."

// A melo window's frame: border and insets, the window's shape and its edge cuts,
// the ground, the title bar with close, and the glass. EqWindow, SettingsWindow
// and Main each carry their own copy of this frame.
// Content goes in `body`, inside the frame and the cuts. No default-property alias
// redirects the frame's own children: in QML it also swallows the declaring
// file's own children.
Window {
    id: win

    property string heading: ""
    readonly property Item body: bodyItem
    // the close in the title bar and Escape; hides unless the window says otherwise
    signal closeRequested()
    onCloseRequested: visible = false

    visible: false
    color: "transparent"
    flags: Qt.Window | Qt.FramelessWindowHint

    function openWindow() {
        applyGlass()
        visible = true
        requestActivate()
    }

    // A rounded corner is at most half its rectangle's height, so the title bar
    // draws less than the window radius when it is short; the ground and the
    // border above it follow what it draws, or the bar pokes past their curve
    readonly property real topCornerRadius: framed && !Theme.borderTitle ? Theme.windowRadius
        : Math.min(Theme.windowRadius, Theme.titleBarH / 2)
    // What the window's shape cuts from each edge (WindowShapeItem.intrusion):
    // the title bar's ends, and the body under it
    property real cutTitleL: 0
    property real cutTitleR: 0
    property real cutBodyL: 0
    property real cutBodyR: 0
    readonly property bool shaped: shapeLoader.item && shapeLoader.item.active && shapeLoader.item.hasShape
    function readCuts() {
        const sh = shapeLoader.item
        const titleH = Theme.titleBarH
        cutTitleL = shaped ? Math.max(frL, sh.intrusion("left", 0, titleH)) : frL
        cutTitleR = shaped ? Math.max(frR, sh.intrusion("right", 0, titleH)) : frR
        cutBodyL = shaped ? Math.max(frL, sh.intrusion("left", titleH, height)) : frL
        cutBodyR = shaped ? Math.max(frR, sh.intrusion("right", titleH, height)) : frR
    }
    onShapedChanged: readCuts()
    readonly property bool frameOff: (win.visibility === Window.Maximized || win.visibility === Window.FullScreen)
                                     && !Theme.borderMaximized
    readonly property real frL: frameOff ? 0 : Theme.borderLeft
    readonly property real frT: frameOff ? 0 : Theme.borderTop
    readonly property real frR: frameOff ? 0 : Theme.borderRight
    readonly property real frB: frameOff ? 0 : Theme.borderBottom
    readonly property bool framed: frL > 0 || frT > 0 || frR > 0 || frB > 0
    readonly property real titleGap: Theme.borderTitle ? frT : 0
    readonly property real titleCap: framed && !Theme.borderTitle ? Math.max(0, Theme.windowRadius - Math.max(frL, frT)) : Theme.windowRadius

    function applyGlass() {
        if (typeof WindowCtl === "undefined") return
        const on = Theme.glassBlur !== "off" && Theme.translucent("window")
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(win, on)
    }
    Connections {
        target: typeof ThemeBackend !== "undefined" ? ThemeBackend : null
        function onThemeChanged() { if (win.visible) win.applyGlass() }
    }

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
        topLeftRadius: win.topCornerRadius; topRightRadius: win.topCornerRadius
        bottomLeftRadius: Theme.windowRadiusBottom; bottomRightRadius: Theme.windowRadiusBottom
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.y + titleBar.height + win.titleGap
        anchors.leftMargin: win.shaped ? 0 : win.frL
        anchors.rightMargin: win.shaped ? 0 : win.frR
        anchors.bottomMargin: win.shaped ? 0 : win.frB
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frL, win.frB))
        bottomRightRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frR, win.frB))
        visible: Theme.hasPage
    }
    Loader {   // the window's shape (WindowMask)
        id: shapeLoader
        parent: win.contentItem
        anchors.fill: parent
        z: 10000000
        active: typeof WindowCtl !== "undefined"
        source: "WindowMask.qml"
        onLoaded: {
            item.shapeApplied.connect(win.readCuts)
            item.spec = Qt.binding(() => Theme.panelShapeFor(win.topCornerRadius, Theme.windowRadiusBottom))
            item.active = Qt.binding(() => item.spec !== null && win.visibility !== Window.Maximized
                                           && win.visibility !== Window.FullScreen)
        }
    }
    WindowBorder {   // the window frame and border; with the title in it, round the title too
        anchors.fill: parent
        borderLeft: win.frL; borderTop: win.frT; borderRight: win.frR; borderBottom: win.frB
        titleHeight: Theme.borderTitle && !win.frameOff ? titleBar.height : 0
        shape: shapeLoader.item && shapeLoader.item.active ? shapeLoader.item : null
        titleRim: win.frameOff ? 0 : Theme.borderTitleRim
        titleFade: Theme.borderTitleFade
        radiusTL: win.topCornerRadius
        radiusTR: win.topCornerRadius
        radiusBL: Theme.windowRadiusBottom; radiusBR: Theme.windowRadiusBottom
        visible: win.framed || (!win.frameOff && Theme.frameDepth > 0)
        z: 1000
    }

    Surface {   // title bar
        id: titleBar
        x: Theme.borderTitle ? 0 : win.frL
        y: Theme.borderTitle ? 0 : win.frT
        width: parent.width - (Theme.borderTitle ? 0 : win.frL + win.frR)
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Math.min(win.titleCap, height / 2)
        topRightRadius: Math.min(win.titleCap, height / 2)
        MouseArea { anchors.fill: parent; onPressed: win.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left
            anchors.leftMargin: Theme.inset("title", "left") + win.cutTitleL - (Theme.borderTitle ? 0 : win.frL)
            text: win.heading
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(Theme.titleFontSize); family: Theme.fontFamily; weight: Theme.titleWeight }
        }
        Item {
            anchors.right: parent.right
            anchors.rightMargin: Theme.inset("title", "right") + win.cutTitleR - (Theme.borderTitle ? 0 : win.frR)
            // on whole pixels, as the main window's buttons are
            y: Math.round((parent.height - height + Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2)
            width: Theme.titleButtons === "button" ? Theme.titleBtn : Theme.ctl(26)
            height: Theme.titleButtons === "button" && Number(Theme.ts.titleButtonSize) > 0 ? Theme.titleBtn : Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(13)
                ink: closeMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: closeMa.containsMouse; pressed: closeMa.pressed
                frameWidth: Theme.titleBtn; frameHeight: Theme.titleBtnH }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: win.closeRequested() }
        }
    }

    Item {
        id: bodyItem
        anchors.top: titleBar.bottom
        anchors.topMargin: win.titleGap
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: win.cutBodyL
        anchors.rightMargin: win.cutBodyR
        anchors.bottomMargin: win.shaped ? 0 : win.frB
    }

    Shortcut { sequence: "Escape"; onActivated: win.closeRequested() }
}
