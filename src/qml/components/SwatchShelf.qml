import QtQuick
import QtQuick.Window
import ".."

// Saved entries, by name. A swatch click writes a copy into the role, so a theme
// file is complete on its own. Theme swatches stamp the entry with `from: id`;
// editing the swatch rewrites every stamped role, and a deleted swatch's stamp is
// inert. Personal swatches are never stamped.
Window {
    id: shelf
    property var picker: null
    visible: false
    color: "transparent"
    title: "melo swatches"
    flags: Qt.Window | Qt.FramelessWindowHint
    minimumWidth: Theme.sp(340)
    minimumHeight: Theme.ctl(64)

    // the body's edge: the tool-window inset, `pad` the vertical one for the height sums
    readonly property real pad: Theme.inset("tool", "top")
    readonly property real padB: Theme.inset("tool", "bottom")
    readonly property real gap: Theme.gap(6)

    // [{ id, name, entry }], oldest first
    property var swatches: []
    readonly property bool themeSection: shelf.visible || shelf.themeSwatches.length > 0
    // The theme's own swatches: roles using one are stamped and follow its edits,
    // and they travel with the theme. The personal shelf below applies by value.
    property int themeSwatchRev: 0   // themeSwatchesChanged: no appearance key moves, so Theme.p does not fire
    readonly property var themeSwatches: {
        const dep = Theme.p   // re-read when the theme does; both come from themeChanged
        const rev = shelf.themeSwatchRev
        if (typeof ThemeBackend === "undefined") return []
        const v = ThemeBackend.themeSwatches()
        const out = []
        if (v && typeof v.length === "number")
            for (let i = 0; i < v.length; ++i) if (v[i] && v[i].id !== undefined) out.push(v[i])
        return out
    }
    Connections {
        target: typeof ThemeBackend !== "undefined" ? ThemeBackend : null
        function onThemeSwatchesChanged() { shelf.themeSwatchRev++ }
    }
    // the picker's current entry, named, on the theme — and the role being
    // edited uses it from now on
    function addToTheme(name) {
        if (!picker || typeof ThemeBackend === "undefined") return
        const n = String(name).trim()
        if (n.length === 0) return
        const id = newId()
        Theme.setThemeSwatch(id, n, picker.currentValue())
        picker.entryFrom = id
    }
    // The picker's current entry becomes the swatch's and lands on each role
    // stamped with its id — the one being edited included, which is why the picker
    // keeps the stamp rather than letting go of it as an edit would.
    function updateTheme(id) {
        if (!picker || typeof ThemeBackend === "undefined") return
        Theme.setThemeSwatch(id, "", picker.currentValue())
        picker.entryFrom = String(id)
    }
    function stamped(entry, id) { return Theme.stamped(entry, id) }
    function dropFromTheme(id) {
        if (typeof ThemeBackend === "undefined") return
        ThemeBackend.setThemeSwatches(withoutId(themeSwatches, id))
    }
    function withoutId(list, id) { return list.filter(s => s.id !== id) }
    function promote(sw) {
        // a copy, under an id of its own: editing it later must not look like
        // editing the theme's
        const list = swatches.slice()
        list.push(({ id: newId(), name: sw.name, entry: sw.entry }))
        store(list)
    }
    function hasByName(name) {
        for (let i = 0; i < swatches.length; ++i) if (swatches[i].name === name) return true
        return false
    }
    function load() {
        const v = typeof Settings !== "undefined" ? Settings.uiGet("swatches", []) : []
        const out = []
        if (v && typeof v.length === "number")
            for (let i = 0; i < v.length; ++i)
                if (v[i] && v[i].id !== undefined) out.push(v[i])
        swatches = out
    }
    function store(list) {
        swatches = list
        if (typeof Settings !== "undefined") Settings.uiSet("swatches", list)
    }
    function newId() {
        return "s" + Date.now().toString(36) + Math.floor(Math.random() * 4096).toString(36)
    }
    function add(name) {
        if (!picker) return
        const n = String(name).trim()
        if (n.length === 0) return
        const list = swatches.slice()
        list.push(({ id: newId(), name: n, entry: picker.currentValue() }))
        store(list)
    }
    function drop(id) { store(withoutId(swatches, id)) }
    // a personal swatch takes the picker's entry; nothing placed changes
    function update(id) {
        if (!picker) return
        store(swatches.map(s => s.id === id ? ({ id: s.id, name: s.name, entry: picker.currentValue() }) : s))
    }

    function openBeside() {
        load()
        applyGlass()
        if (picker && picker.visible) {
            width = Math.max(minimumWidth, Math.round(Theme.sp(380)))
            x = picker.x - width - Theme.gap(8)
            y = picker.y
        }
        fitHeight()
        visible = true
        requestActivate()
    }
    function fitHeight() {
        height = Math.max(minimumHeight, Math.round(titleBar.height + body.implicitHeight + pad + padB))
    }
    function applyGlass() {
        if (typeof WindowCtl === "undefined") return
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(shelf, Theme.glassBlur !== "off" && Theme.translucent("window"))
    }
    Connections {
        target: shelf.visible ? body : null
        function onImplicitHeightChanged() { shelf.fitHeight() }
    }
    Connections {
        target: shelf.visible && shelf.picker ? shelf.picker : null
        function onVisibleChanged() { if (!shelf.picker.visible) shelf.visible = false }
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
        MouseArea { anchors.fill: parent; onPressed: shelf.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left; anchors.leftMargin: Theme.inset("title", "left")
            text: "Swatches"
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
                        onClicked: shelf.visible = false }
        }
    }

    Column {
        id: body
        objectName: "swatchShelfBody"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.leftMargin: Theme.inset("tool", "left"); anchors.rightMargin: Theme.inset("tool", "right")
        anchors.topMargin: shelf.pad; anchors.bottomMargin: shelf.padB
        spacing: shelf.gap

        // the theme's — shown while the shelf is open even when it carries
        // none, so one can be put there
        InkText {
            width: parent.width
            visible: shelf.themeSection
            text: "theme"
            ink: "textFaint"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
        }
        Grid {
            objectName: "themeSwatchGrid"
            width: parent.width
            columns: grid.columns
            columnSpacing: Theme.gap(6); rowSpacing: Theme.gap(6)
            visible: shelf.themeSwatches.length > 0
            Repeater {
                model: shelf.themeSwatches
                Item {
                    id: tsw
                    required property var modelData
                    objectName: "themeSwatch_" + modelData.name
                    width: (parent.width - (grid.columns - 1) * Theme.gap(6)) / grid.columns
                    height: Theme.ctl(40) + Theme.fs(13) + Theme.gap(3)
                    Item {
                        id: tswFace
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        height: Theme.ctl(40)
                        Checker { anchors.fill: parent }
                        EntryChip { anchors.fill: parent; entry: tsw.modelData.entry }
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"; radius: Theme.radiusSm
                            border.color: tswMa.containsMouse ? Theme.accent : Theme.border
                        }
                        MouseArea {
                            id: tswMa
                            anchors.fill: parent; hoverEnabled: true
                            onClicked: if (shelf.picker) shelf.picker.applySwatch(tsw.modelData.id, tsw.modelData.entry, true)
                        }
                        Row {
                            anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: Theme.gap(2)
                            spacing: Theme.gap(2)
                            visible: tswMa.containsMouse || keepMa.containsMouse || tswRmMa.containsMouse || tswUpMa.containsMouse
                            component TTool: Rectangle {
                                id: tool
                                property string glyph
                                property bool pressed: false   // its MouseArea is the instance's
                                property bool hovered: false
                                width: Theme.ctl(22); height: Theme.ctl(22)
                                radius: 2
                                color: Theme[Theme.faceOf("button", tool.hovered, tool.pressed)]
                                border.color: tool.hovered ? Theme.borderStrong : Theme.border
                                InkText { anchors.centerIn: parent; text: tool.glyph; ink: "textDim"
                                       anchors.horizontalCenterOffset: Theme.pressShift(tool.pressed)
                                       anchors.verticalCenterOffset: Theme.pressShift(tool.pressed)
                                       font { pixelSize: Theme.fs(12); family: Theme.fontFamily } }
                            }
                            TTool {
                                objectName: "themeSwatchUpdate_" + tsw.modelData.name
                                pressed: tswUpMa.pressed; hovered: tswUpMa.containsMouse
                                glyph: "↻"
                                MouseArea { id: tswUpMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: shelf.updateTheme(tsw.modelData.id) }
                            }
                            TTool {
                                objectName: "themeSwatchKeep_" + tsw.modelData.name
                                pressed: keepMa.pressed; hovered: keepMa.containsMouse
                                glyph: "+"
                                MouseArea { id: keepMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: shelf.promote(tsw.modelData) }
                            }
                            TTool {
                                objectName: "themeSwatchDrop_" + tsw.modelData.name
                                pressed: tswRmMa.pressed; hovered: tswRmMa.containsMouse
                                glyph: "\u00d7"
                                MouseArea { id: tswRmMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: shelf.dropFromTheme(tsw.modelData.id) }
                            }
                        }
                    }
                    InkText {
                        anchors.top: tswFace.bottom; anchors.topMargin: 1
                        width: parent.width
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: tsw.modelData.name
                        ink: shelf.hasByName(tsw.modelData.name) ? "textFaint" : "textDim"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    }
                }
            }
        }
        // the current entry, named, onto the theme
        Row {
            width: parent.width
            spacing: Theme.gap(6)
            visible: shelf.themeSection
            Surface {
                width: parent.width - themeAddBtn.width - Theme.gap(6)
                height: Theme.ctl(28)
                radius: Theme.radiusSm
                role: "input"
                borderWidth: 1
                borderRole: themeNameIn.activeFocus ? "borderStrong" : "border"
                TextInput {
                    id: themeNameIn
                    objectName: "themeSwatchName"
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    clip: true
                    selectByMouse: true
                    Keys.onReturnPressed: { shelf.addToTheme(text); text = "" }
                }
            }
            PushButton {
                id: themeAddBtn
                objectName: "themeSwatchAdd"
                enabled: themeNameIn.text.length > 0
                width: Theme.ctl(56)
                radius: Theme.radiusSm
                label: "add"; ink: "textDim"
                onClicked: { shelf.addToTheme(themeNameIn.text); themeNameIn.text = "" }
            }
        }
        InkText {
            width: parent.width
            visible: shelf.swatches.length > 0
            text: "yours"
            ink: "textFaint"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
        }
        Grid {
            id: grid
            objectName: "swatchGrid"
            width: parent.width
            columns: Math.max(2, Math.floor((width + Theme.gap(4)) / (Theme.ctl(96) + Theme.gap(6))))
            columnSpacing: Theme.gap(6); rowSpacing: Theme.gap(6)
            visible: shelf.swatches.length > 0
            Repeater {
                model: shelf.swatches
                Item {
                    id: sw
                    required property var modelData
                    objectName: "swatch_" + modelData.name
                    width: (grid.width - (grid.columns - 1) * Theme.gap(6)) / grid.columns
                    height: Theme.ctl(40) + Theme.fs(13) + Theme.gap(3)
                    Item {
                        id: swFace
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        height: Theme.ctl(40)
                        Checker { anchors.fill: parent }
                        EntryChip { anchors.fill: parent; entry: sw.modelData.entry }
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"; radius: Theme.radiusSm
                            border.color: swMa.containsMouse ? Theme.accent : Theme.border
                        }
                        MouseArea {
                            id: swMa
                            anchors.fill: parent; hoverEnabled: true
                            onClicked: if (shelf.picker) shelf.picker.applySwatch(sw.modelData.id, sw.modelData.entry, false)
                        }
                        Row {
                            anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: Theme.gap(2)
                            spacing: Theme.gap(2)
                            visible: swMa.containsMouse || upMa.containsMouse || rmMa.containsMouse
                            component Tool: Rectangle {
                                id: tool
                                property string glyph
                                property bool pressed: false   // its MouseArea is the instance's
                                property bool hovered: false
                                signal go()
                                width: Theme.ctl(22); height: Theme.ctl(22)
                                radius: 2
                                color: Theme[Theme.faceOf("button", tool.hovered, tool.pressed)]
                                border.color: tool.hovered ? Theme.borderStrong : Theme.border
                                InkText { anchors.centerIn: parent; text: tool.glyph; ink: "textDim"
                                       anchors.horizontalCenterOffset: Theme.pressShift(tool.pressed)
                                       anchors.verticalCenterOffset: Theme.pressShift(tool.pressed)
                                       font { pixelSize: Theme.fs(12); family: Theme.fontFamily } }
                            }
                            Tool {
                                objectName: "swatchUpdate_" + sw.modelData.name
                                pressed: upMa.pressed; hovered: upMa.containsMouse
                                glyph: "↻"
                                MouseArea { id: upMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: shelf.update(sw.modelData.id) }
                            }
                            Tool {
                                objectName: "swatchDrop_" + sw.modelData.name
                                pressed: rmMa.pressed; hovered: rmMa.containsMouse
                                glyph: "×"
                                MouseArea { id: rmMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: shelf.drop(sw.modelData.id) }
                            }
                        }
                    }
                    InkText {
                        anchors.top: swFace.bottom; anchors.topMargin: 1
                        width: parent.width
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: sw.modelData.name
                        ink: "textDim"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    }
                }
            }
        }

        // the current entry, saved under a name
        Row {
            width: parent.width
            spacing: Theme.gap(6)
            Surface {
                width: parent.width - saveBtn.width - Theme.gap(6)
                height: Theme.ctl(28)
                radius: Theme.radiusSm
                role: "input"
                borderWidth: 1
                borderRole: nameIn.activeFocus ? "borderStrong" : "border"
                TextInput {
                    id: nameIn
                    objectName: "swatchName"
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    clip: true
                    selectByMouse: true
                    Keys.onReturnPressed: { shelf.add(text); text = "" }
                }
            }
            PushButton {
                id: saveBtn
                objectName: "swatchSave"
                enabled: nameIn.text.length > 0
                width: Theme.ctl(56)
                radius: Theme.radiusSm
                label: "save"; ink: "textDim"
                onClicked: { shelf.add(nameIn.text); nameIn.text = "" }
            }
        }
    }

    Shortcut { sequence: "Escape"; enabled: shelf.visible; onActivated: shelf.visible = false }
}
