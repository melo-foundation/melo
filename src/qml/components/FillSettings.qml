import QtQuick
import QtQuick.Window
import ".."

// A fill kind's own options (a grain, a pitch, the horizon) beyond speed, scale
// and angle, built from the kind's table in Theme. A window rather than a row in
// the picker: up to eight per kind would push OK off the bottom.
Window {
    id: fs
    property var picker: null
    visible: false
    color: "transparent"
    title: "melo fill settings"
    flags: Qt.Window | Qt.FramelessWindowHint
    minimumWidth: Theme.sp(260)
    minimumHeight: Theme.ctl(90)

    readonly property var options: picker ? Theme.fillOptions(picker.sourceMode) : []
    readonly property bool image: picker !== null && picker.sourceMode === "image"
    // the body's edge: the tool-window inset, `pad` the vertical one for the height sums
    readonly property real pad: Theme.inset("tool", "top")
    readonly property real padB: Theme.inset("tool", "bottom")
    readonly property real gap: Theme.gap(6)

    function openBeside() {
        applyGlass()
        if (picker && picker.visible) {
            width = Math.max(minimumWidth, Math.round(Theme.sp(300)))
            x = picker.x + picker.width + Theme.gap(8)
            y = picker.y + Theme.gap(8)
        }
        fitHeight()
        visible = true
        requestActivate()
    }
    function fitHeight() {
        height = Math.max(minimumHeight, Math.round(titleBar.height + rows.implicitHeight + pad + padB))
    }
    function applyGlass() {
        if (typeof WindowCtl === "undefined") return
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(fs, Theme.glassBlur !== "off" && Theme.translucent("window"))
    }
    // a kind with nothing of its own has nothing to show, and the picker
    // going away takes this with it
    onOptionsChanged: if (visible && options.length === 0) visible = false
    // Follow the content. A Column's implicitHeight is a layout result, so
    // reading it in the same turn the window is opened gives the height of a
    // column that has not been laid out — the window comes up at its minimum
    // and stays there.
    Connections {
        target: fs.visible ? rows : null
        function onImplicitHeightChanged() { fs.fitHeight() }
    }
    Connections {
        target: fs.visible && fs.picker ? fs.picker : null
        function onVisibleChanged() { if (!fs.picker.visible) fs.visible = false }
    }

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.height
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Theme.windowRadius; bottomRightRadius: Theme.windowRadius
        visible: Theme.hasPage
    }
    Surface {
        anchors.fill: parent
        role: ""
        radius: Theme.windowRadius
        borderRole: "windowBorder"
        borderWidth: Theme.windowBorderWidth
        visible: Theme.windowBorder
        z: 1000
    }
    Surface {
        id: titleBar
        width: parent.width
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Theme.windowRadius
        topRightRadius: Theme.windowRadius
        MouseArea { anchors.fill: parent; onPressed: fs.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left; anchors.leftMargin: Theme.inset("title", "left")
            text: fs.picker ? Theme.sourceName(fs.picker.sourceMode) : ""
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightMedium }
        }
        Item {
            anchors.right: parent.right; anchors.rightMargin: Theme.inset("title", "right")
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            width: Theme.ctl(26); height: Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                ink: xMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: xMa.containsMouse; pressed: xMa.pressed
                frameWidth: Theme.iconBtn; frameHeight: Math.min(Theme.iconBtn, Theme.ctl(20) + Theme.inset("title", "top") + Theme.inset("title", "bottom")) }
            MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: fs.visible = false }
        }
    }

    Column {
        id: rows
        objectName: "fillSettingsBody"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.leftMargin: Theme.inset("tool", "left"); anchors.rightMargin: Theme.inset("tool", "right")
        anchors.topMargin: fs.pad; anchors.bottomMargin: fs.padB
        spacing: Theme.gap(2)
        Loader {
            width: rows.width
            active: fs.image
            visible: active
            sourceComponent: ImageFillSettings { picker: fs.picker }
        }
        Repeater {
            model: fs.image ? [] : fs.options
            Item {
                id: optRow
                required property var modelData
                objectName: "fillOption_" + modelData.name
                readonly property real amount: fs.picker ? fs.picker.optionOf(modelData.name) : 0
                function apply(v) { if (fs.picker) fs.picker.setOption(modelData.name, v) }
                // A row shows when the option it waits on says so: `when` names
                // one option and the value it has to hold
                readonly property bool shown: {
                    const w = modelData.when
                    if (!w || !fs.picker) return true
                    for (const k in w) if (Math.round(fs.picker.optionOf(k)) !== w[k]) return false
                    return true
                }
                readonly property bool isToggle: Theme.isList(modelData.toggle)
                visible: shown
                width: rows.width
                height: shown ? Theme.ctl(24) : 0
                InkText {
                    id: optName
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.sp(72)
                    text: optRow.modelData.label
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                InkText {
                    id: optVal
                    visible: !optRow.isToggle
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    width: Theme.sp(48)
                    horizontalAlignment: Text.AlignRight
                    // an integer step is an integer: 48 pixels, not 48.00
                    text: (optRow.modelData.zero !== undefined && optRow.amount === 0 ? optRow.modelData.zero
                        : optRow.modelData.step >= 1 ? String(Math.round(optRow.amount))
                                                     : optRow.amount.toFixed(2))
                        + (optRow.modelData.unit !== undefined ? optRow.modelData.unit : "")
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                // A toggle: two words, the one held lit, the same shape as
                // the picker's mask row
                Row {
                    visible: optRow.isToggle
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    spacing: Theme.gap(4)
                    Repeater {
                        model: optRow.isToggle ? optRow.modelData.toggle : []
                        Surface {
                            required property int index
                            required property string modelData
                            objectName: "fillToggle_" + optRow.modelData.name + "_" + index
                            readonly property bool on: Math.round(optRow.amount) === index
                            width: Theme.ctl(52); height: Theme.ctl(20)
                            radius: Theme.radiusSm
                            role: on ? "accent" : Theme.faceOf("segment", tMa.containsMouse)
                            InkText { objectName: "fillToggleInk"
                                      anchors.centerIn: parent; text: parent.modelData
                                      ink: parent.on ? "textOnAccent" : "textDim"
                                      font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                            MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: optRow.apply(index) }
                        }
                    }
                }
                MSlider {
                    visible: !optRow.isToggle
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: optName.right
                    anchors.leftMargin: Theme.gap(8)
                    anchors.right: optVal.left
                    anchors.rightMargin: Theme.gap(8)
                    // a toggle row has no range; the slider it hides still binds
                    from: optRow.isToggle ? 0 : optRow.modelData.from
                    to: optRow.isToggle ? 1 : optRow.modelData.to
                    step: optRow.isToggle ? 1 : optRow.modelData.step
                    value: optRow.amount
                    onLiveChanged: optRow.apply(live)
                    onCommitted: (v) => optRow.apply(v)
                }
            }
        }
    }

    Shortcut { sequence: "Escape"; enabled: fs.visible; onActivated: fs.visible = false }
}
