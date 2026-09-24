import QtQuick
import QtQuick.Window
import ".."

// Visualizer config popover (projectM knobs).
// Controls hold their own state, loaded in open(): a binding to Settings.uiGet()
// is a plain call and never re-evaluates. Writes go through uiSet; Settings.changed()
// re-applies to the engine (applyVisSettings in Main).
// A Window, not an Item: compositor blur applies per surface.
Window {
    id: panel
    flags: Qt.Popup | Qt.FramelessWindowHint
    color: "transparent"
    visible: false
    width: 260
    // as tall as its rows plus the panel inset above and below
    height: col.implicitHeight + Theme.inset("panel", "top") + Theme.inset("panel", "bottom")

    // The height is bound to the content and settles a frame after show, so
    // the glass follows the size rather than being applied once on show —
    // the same reason DropMenu reapplies here.
    function applyGlass() {
        if (!panel.visible) return
        WindowCtl.setBlurRadius(Theme.radiusMd)
        WindowCtl.setBlurBehind(panel, Theme.menuBlur)
        WindowCtl.setBackgroundContrast(panel, Theme.menuBlur, Theme.glassContrast, Theme.glassSaturation)
    }
    onVisibleChanged: applyGlass()
    onWidthChanged: applyGlass()
    onHeightChanged: applyGlass()
    // clicking away closes it
    onActiveChanged: if (!active && visible) visible = false

    // the panel's ground: the window itself is transparent
    Surface {
        anchors.fill: parent
        radius: Theme.radiusMd
        role: "menu"
        borderWidth: 1
        borderRole: "border"
    }

    property var viz: null   // Visualizer item: presetNames + playPresetAt
    property bool lock: false
    // [{name, idx}] — idx is the PLAYLIST position, kept through filtering
    readonly property var presetHits: {
        const q = presetSearch.text.toLowerCase()
        if (!viz || q.length < 2) return []
        const names = viz.presetNames
        const hits = []
        for (let i = 0; i < names.length && hits.length < 50; ++i)
            if (names[i].toLowerCase().includes(q)) hits.push({ name: names[i], idx: i })
        return hits
    }

    // `anchor` is the gear button; the panel opens right-aligned under it.
    // Window coords ->
    // global: Wayland reports the host at 0,0 so the add is a no-op there; on
    // X11 it contributes the real position.
    function open(anchor) {
        lock = Settings.uiGet("visPresetLocked", false) === true
        beatSlider.value = Number(Settings.uiGet("visBeatSensitivity", 1))
        durSlider.value = Number(Settings.uiGet("visPresetDuration", 30))
        shuffleToggle.checked = Settings.uiGet("visShuffle", true) !== false
        randClickToggle.checked = Settings.uiGet("visRandomClick", false) === true
        presetSearch.text = ""
        const host = anchor.Window.window
        const below = anchor.mapToItem(null, anchor.width, anchor.height + Theme.gap(6))
        panel.transientParent = host
        panel.x = host.x + below.x - panel.width
        panel.y = host.y + below.y
        visible = true
    }

    component CToggle: MToggle { }
    component CSlider: MSlider { width: 120; height: 20 }

    component PLabel: InkText {
        anchors.verticalCenter: parent.verticalCenter
        ink: "text"
        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
    }

    Column {
        id: col
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.inset("panel", "left"); anchors.rightMargin: Theme.inset("panel", "right")
        anchors.topMargin: Theme.inset("panel", "top"); anchors.bottomMargin: Theme.inset("panel", "bottom")
        spacing: Theme.gap(10)

        Item {
            width: parent.width; height: 22
            PLabel { text: "Beat sensitivity" }
            PLabel {
                anchors.right: beatSlider.left; anchors.rightMargin: Theme.gap(8)
                text: (Math.round(beatSlider.shown * 10) / 10) + "×"
                color: Theme.textDim
            }
            CSlider {
                id: beatSlider
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                from: 0.2; to: 3; step: 0.1
                onCommitted: (v) => Settings.uiSet("visBeatSensitivity", Math.round(v * 10) / 10)
            }
        }
        Item {
            width: parent.width; height: 22
            PLabel { text: "Preset lock" }
            CToggle {
                checked: panel.lock
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                onToggled: (v) => { panel.lock = v; Settings.uiSet("visPresetLocked", v) }
            }
        }
        Item {
            visible: !panel.lock
            width: parent.width; height: 22
            PLabel { text: "Preset duration" }
            PLabel {
                anchors.right: durSlider.left; anchors.rightMargin: Theme.gap(8)
                text: Math.round(durSlider.shown) + "s"
                color: Theme.textDim
            }
            CSlider {
                id: durSlider
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                from: 5; to: 120; step: 5
                onCommitted: (v) => Settings.uiSet("visPresetDuration", Math.round(v))
            }
        }
        Item {
            visible: !panel.lock
            width: parent.width; height: 22
            PLabel { text: "Shuffle presets" }
            CToggle {
                id: shuffleToggle
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                onToggled: (v) => { checked = v; Settings.uiSet("visShuffle", v) }
            }
        }
        Item {
            width: parent.width; height: 22
            PLabel { text: "Random preset on click" }
            CToggle {
                id: randClickToggle
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                onToggled: (v) => { checked = v; Settings.uiSet("visRandomClick", v) }
            }
        }

        Surface {   // preset search
            width: parent.width; height: 24
            radius: Theme.radiusSm
            role: "input"
            borderWidth: 1
            borderRole: presetSearch.activeFocus ? "borderStrong" : "border"
            TextInput {
                id: presetSearch
                anchors.fill: parent
                anchors.leftMargin: Theme.gap(8)
                anchors.rightMargin: Theme.gap(8)
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                clip: true
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                InkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !presetSearch.text
                    text: "Search presets"
                    ink: "textFaint"
                    font: presetSearch.font
                }
            }
        }
        ListView {
            id: presetList
            visible: count > 0
            width: parent.width
            height: Math.min(count, 6) * 24
            clip: true
            model: panel.presetHits
            WheelScroll { parent: presetList; target: presetList }
            delegate: Surface {
                required property var modelData
                width: ListView.view.width; height: 24
                radius: Theme.radiusSm
                role: hitMa.containsMouse ? "hover" : ""
                InkText {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 6; width: parent.width - 12
                    elide: Text.ElideRight
                    text: modelData.name
                    ink: "text"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                MouseArea {
                    id: hitMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: panel.viz.playPresetAt(modelData.idx)
                }
            }
        }
        InkText {
            visible: presetSearch.text.length >= 2 && panel.presetHits.length === 0
            text: "No matches"
            ink: "textFaint"
            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
        }
    }
}
