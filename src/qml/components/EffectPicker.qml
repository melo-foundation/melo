import QtQuick
import ".."

// The effect of one ink, edited with the result in view: sample words in that
// ink, the kind, the levers and the colour.
// openFor(key, commit, preview, pickColour): commit(patch) on OK or a click off
// the picker, preview(patch) on every change, pickColour(entry, cb, live) hands
// the colour to the colour picker. Escape cancels: the preview goes back to the
// original and nothing is committed.
Item {
    id: ep
    anchors.fill: parent
    visible: false
    z: 41

    property string inkKey: ""
    property var original: null
    property var eff: null           // the working effect, a plain object
    property var commitCb: null
    property var previewCb: null
    property var pickColour: null
    readonly property var kinds: ["off", "glow", "outline", "shadow"]
    readonly property bool on: eff !== null && eff.kind !== "off"

    function openFor(key, commit, preview, colourPicker) {
        inkKey = key
        original = Object.assign({}, Theme.inkRole(key).effect)
        eff = Object.assign({}, original)
        commitCb = commit; previewCb = preview; pickColour = colourPicker
        visible = true
    }
    function patch(p) {
        // Skip a value already held, or a slider echoing its value loops through eff and
        // the levers. Colours compare by content and are copied: the colour picker hands
        // back the one entry it edits in place, so `!==` would skip the preview.
        const same = (a, b) => (a !== null && typeof a === "object") || (b !== null && typeof b === "object")
                               ? JSON.stringify(a) === JSON.stringify(b) : a === b
        let changed = false
        for (const k in p) if (!same(eff[k], p[k])) changed = true
        if (!changed) return
        const e = Object.assign({}, eff)
        for (const k in p) e[k] = (p[k] !== null && typeof p[k] === "object") ? JSON.parse(JSON.stringify(p[k])) : p[k]
        eff = e
        if (previewCb) previewTick.restart()
    }
    Timer { id: previewTick; interval: 30; onTriggered: if (ep.previewCb) ep.previewCb(ep.eff) }
    function accept() { visible = false; previewTick.stop(); const f = commitCb; commitCb = null; if (f) f(eff) }
    function reject() { visible = false; previewTick.stop(); if (previewCb) previewCb(original); commitCb = null }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        // clicking off the picker keeps what it shows; only Escape puts it back
        MouseArea { anchors.fill: parent; onClicked: ep.accept() }
    }
    Surface {
        anchors.centerIn: parent
        width: Math.min(340, ep.width - Theme.gap(24))
        height: Math.min(col.implicitHeight + 24, ep.height - Theme.gap(16))
        radius: Theme.radiusLg
        role: "dialog"
        borderWidth: 1
        borderRole: "border"
        MouseArea { anchors.fill: parent }
        Flickable {
            id: effFlick
            anchors.fill: parent
            anchors.margins: Theme.gap(12)
            contentHeight: col.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            WheelScroll { parent: effFlick; target: effFlick }
            Column {
                id: col
                width: parent.width
                spacing: Theme.gap(8)

                // ---- the words, with the effect on them ----
                // The ground is a sibling of the words, not their parent: an adaptive effect
                // colour reads it as a texture, and a source containing its own reader resolves
                // as empty, drawing an adaptive halo as a flat colour.
                Item {
                    width: parent.width; height: Theme.ctl(64)
                    Surface {
                        id: sampleGround
                        anchors.fill: parent
                        radius: Theme.radiusMd
                        role: "window"
                        borderWidth: 1; borderColor: Theme.border
                    }
                    Text {
                        id: sample
                        anchors.centerIn: parent
                        text: "Aa Bb 123"
                        color: ep.inkKey.length > 0 ? Theme[ep.inkKey] : Theme.text
                        font { pixelSize: Theme.fs(24); family: Theme.fontFamily; weight: Theme.weightMedium }
                        Loader {
                            z: -1
                            active: ep.on
                            source: "TextHalo.qml"
                            onLoaded: {
                                item.label = sample
                                item.inside = true
                                item.effect = Qt.binding(() => ep.eff)
                                item.colour = Qt.binding(() => ep.eff ? Theme.effectColour(ep.eff, sample.color) : "#000000")
                                item.backdrop = sampleGround
                            }
                        }
                    }
                }

                // ---- kind ----
                Flow {
                    width: parent.width
                    spacing: Theme.gap(4)
                    Repeater {
                        model: ep.kinds
                        Surface {
                            required property string modelData
                            readonly property bool on: ep.eff && ep.eff.kind === modelData
                            height: Theme.ctl(22)
                            width: kT.implicitWidth + Theme.gap(16)
                            radius: Theme.radiusSm
                            role: on ? "accent" : Theme.faceOf("segment", kMa.containsMouse)
                            borderWidth: 1
                            borderRole: on ? "accent" : "border"
                            Text {
                                id: kT
                                anchors.centerIn: parent
                                text: parent.modelData
                                color: parent.on ? Theme.onAccent : Theme.textDim
                                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                            }
                            MouseArea { id: kMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: ep.patch({ kind: parent.modelData }) }
                        }
                    }
                }

                // ---- levers ----
                Column {
                    width: parent.width
                    spacing: Theme.gap(4)
                    visible: ep.on
                    component Lever: Item {
                        id: lv
                        property string label
                        property string prop
                        property real from: 0
                        property real to: 1
                        property real step: 0.05
                        property string unitText: ""
                        readonly property real amount: ep.eff ? Number(ep.eff[prop]) : 0
                        width: parent.width
                        height: Theme.ctl(24)
                        InkText {
                            id: lvName
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            width: Theme.gap(60)
                            text: lv.label
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        InkText {
                            id: lvVal
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            width: Theme.gap(40)
                            horizontalAlignment: Text.AlignRight
                            text: (lv.step >= 1 ? Math.round(lv.amount) : lv.amount.toFixed(lv.step >= 0.5 ? 1 : 2)) + lv.unitText
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        MSlider {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: lvName.right; anchors.leftMargin: Theme.gap(8)
                            anchors.right: lvVal.left; anchors.rightMargin: Theme.gap(8)
                            from: lv.from; to: lv.to; step: lv.step
                            value: lv.amount
                            onLiveChanged: { const o = {}; o[lv.prop] = live; ep.patch(o) }
                            onCommitted: (v) => { const o = {}; o[lv.prop] = v; ep.patch(o) }
                        }
                    }
                    Lever { label: "size"; prop: "size"; from: 0; to: 8; step: 0.5 }
                    Lever { label: "softness"; prop: "soft"; from: 0; to: 1; step: 0.05
                            visible: ep.eff && ep.eff.kind !== "glow" }
                    Lever { label: "offset x"; prop: "dx"; from: -8; to: 8; step: 1
                            visible: ep.eff && ep.eff.kind === "shadow" }
                    Lever { label: "offset y"; prop: "dy"; from: -8; to: 8; step: 1
                            visible: ep.eff && ep.eff.kind === "shadow" }
                    Lever { label: "opacity"; prop: "opacity"; from: 0; to: 1; step: 0.05 }
                }

                // ---- colour, and OK ----
                Row {
                    width: parent.width
                    spacing: Theme.gap(8)
                    visible: ep.on
                    Surface {
                        width: Theme.ctl(64); height: Theme.btnH
                        radius: Theme.radiusMd
                        role: Theme.faceOf("button", cMa.containsMouse, cMa.pressed)
                        borderWidth: 1
                        borderRole: cMa.containsMouse ? "borderStrong" : "border"
                        EntryChip {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: Theme.pressShift(cMa.pressed)
                            anchors.verticalCenterOffset: Theme.pressShift(cMa.pressed)
                            width: Theme.ctl(44); height: Theme.ctl(14)
                            entry: ep.eff ? ep.eff.colour : "#000000"
                            fallback: ep.eff ? Theme.effectColour(ep.eff, sample.color) : "#000000"
                        }
                        MouseArea {
                            id: cMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: if (ep.pickColour) ep.pickColour(ep.eff.colour,
                                                                        (c) => ep.patch({ colour: c }),
                                                                        (c) => ep.patch({ colour: c }))
                        }
                    }
                    InkText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: ep.eff ? Theme.sourceName(Theme.sourceOf(ep.eff.colour)) : ""
                        ink: "textDim"
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                }
                PushButton {
                    width: Theme.ctl(52)
                    label: "OK"; accent: true; fontSize: 12
                    onClicked: ep.accept()
                }
            }
        }
    }
    Shortcut { sequence: "Escape"; enabled: ep.visible; onActivated: ep.reject() }
}
