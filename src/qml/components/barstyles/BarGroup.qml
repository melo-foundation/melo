import QtQuick
import ".."
import "../.."

// The bar buttons a document's cell names: library and radio act on the
// track, eq, queue and vis on the app, and a plugin's button runs its
// command.
Row {
    id: root
    property var bar
    property string layout: "rows"
    property string side: "right"     // "left" or "right"
    property int size: Theme.ctl(22)
    property real stroke: 2
    spacing: Theme.gap(6)
    // the buttons, named outright by a document's cell; none otherwise
    property var explicitIds: null
    readonly property var ids: explicitIds !== null ? explicitIds : []
    // the settings editor draws over the real buttons: every one shown,
    // and each says where it is
    readonly property bool customising: bar ? bar.customising === true : false
    function rectOf(id, target) {
        for (let i = 0; i < rep.count; ++i) {
            const it = rep.itemAt(i)
            if (it && it.modelData === id) return it.mapToItem(target, 0, 0, it.width, it.height)
        }
        return null
    }

    // isInLibrary is a call, not a property, so it is re-asked whenever the
    // library or the track changes rather than bound and left stale.
    property bool inLibrary: false
    function refresh() {
        const t = PlayerState.currentTrack
        inLibrary = !!(t && t.id) && Library.isInLibrary(t.id)
    }
    Connections { target: Library; function onCountsChanged() { root.refresh() } }
    Connections { target: PlayerState; function onTrackChanged() { root.refresh() } }
    Component.onCompleted: refresh()

    readonly property bool localTrack: !!PlayerState.currentTrack
                                       && String(PlayerState.currentTrack.id || "").startsWith("local-")
    // A plugin's button is one of these too: "plugin:<pluginId>.<id>", drawn
    // from the registry's icon and pressed through its command. One that
    // names a plugin not here is not drawn.
    function pluginOf(id) {
        if (!id.startsWith("plugin:") || typeof BarButtons === "undefined" || !BarButtons) return null
        const dep = BarButtons.generation
        const key = id.slice(7)
        for (const b of BarButtons.all()) if (b.pluginId + "." + b.id === key) return b
        return null
    }
    function glyphOf(id) {
        return id === "library" ? (inLibrary ? "check" : "plus") : id
    }
    function activeOf(id) {
        switch (id) {
        case "library": return inLibrary
        case "radio": return PlayerState.radioActive
        case "eq":    return bar ? bar.eqActive === true : false
        case "queue": return PlayerState.showPanel && PlayerState.hasTrack
        case "vis":   return bar ? bar.visActive === true : false
        }
        return false
    }
    function enabledOf(id) {
        if (id.startsWith("plugin:")) return true
        if (id === "eq") return true
        if (id === "radio") return PlayerState.hasTrack && !localTrack
        return PlayerState.hasTrack
    }
    function press(id) {
        const t = PlayerState.currentTrack
        if (id.startsWith("plugin:")) { const b = pluginOf(id); if (b) CommandMap.invoke(b.command); return }
        switch (id) {
        case "library":
            if (!t || !t.id) return
            if (inLibrary) Library.removeTrack(t.id, false); else Library.addTrack(t, false)
            refresh(); break
        case "radio": if (t && t.id) Player.startRadio(t.id); break
        case "eq":    if (bar) bar.eqToggle(); break
        case "queue": if (bar) bar.queueToggle(); break
        case "vis":   if (bar) bar.visToggle(); break
        }
    }

    Repeater {
        id: rep
        model: root.ids
        delegate: Item {
            id: btn
            required property string modelData
            // The visualizer cell is marked `"mini": true` and Theme.stripMini keeps it
            // out of documents it does not belong in; a plugin's button draws only if its
            // plugin is loaded.
            readonly property var plugin: root.pluginOf(modelData)
            readonly property bool shown: modelData.startsWith("plugin:") ? plugin !== null : true
            readonly property bool on: root.enabledOf(modelData)
            width: shown ? root.size + (modelData === "queue" && Queue.count > 1 ? count.implicitWidth + Theme.gap(4) : 0) : 0
            height: root.size
            clip: true
            visible: width > 0.5
            Behavior on width { NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase } }
            Image {   // a plugin's icon
                visible: btn.plugin !== null
                x: (root.size - width) / 2
                anchors.verticalCenter: parent.verticalCenter
                width: root.size - 6; height: root.size - 6
                fillMode: Image.PreserveAspectFit
                smooth: true
                source: btn.plugin ? btn.plugin.icon : ""
                opacity: ma.containsMouse ? 1 : 0.75
                Behavior on opacity { NumberAnimation { duration: Theme.motionFast; easing.type: Theme.motionEase } }
            }
            IconButton {
                id: glyph
                objectName: "barButton"
                visible: btn.plugin === null
                // centred in the button's square; the queue's count sits
                // beside that square, not beside the glyph
                x: (root.size - width) / 2
                anchors.verticalCenter: parent.verticalCenter
                name: root.glyphOf(btn.modelData); size: root.size - 8
                strokeWidth: btn.modelData === "queue" ? 2.5 : root.stroke
                ink: !btn.on ? "controlOff"
                   : root.activeOf(btn.modelData) ? (Theme.transportButtons === "button" ? "textOnActive" : "highlight")
                   : (ma.containsMouse ? "controlHover" : "control")
                framed: Theme.transportButtons === "button"
                active: btn.on && root.activeOf(btn.modelData)
                // off — no track, or a radio on a local file: the face stays
                // flat and the glyph does not sink
                hovered: btn.on && ma.containsMouse
                pressed: btn.on && ma.pressed
                frameWidth: root.size
            }
            InkText {   // the queue's count, beside it
                id: count
                visible: btn.modelData === "queue" && Queue.count > 1
                x: root.size + Theme.gap(4)
                anchors.verticalCenter: parent.verticalCenter
                text: Queue.count
                ink: PlayerState.showPanel ? "highlight" : "textDim"
                font { pixelSize: Theme.fs(13); family: Theme.fontFamily; weight: Theme.weightBase }
            }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                onClicked: if (btn.on) root.press(btn.modelData)
            }
        }
    }
}
