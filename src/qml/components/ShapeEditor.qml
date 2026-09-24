import QtQuick
import QtQuick.Shapes
import ".."

// The window shape, edited as drawn, with the four slice numbers as guides to
// drag: what lies outside them keeps its size on resize, the middle stretches.
Item {
    id: ed
    // { path | image, box, slice, scale, fit } — see WindowShapeItem.h
    property var spec: ({})
    // the edited spec, for the caller to store
    signal changed(var next)

    readonly property bool isImage: "image" in spec
    readonly property var box: {
        const b = spec.box
        if (b && b.length >= 2 && Number(b[0]) > 0) return [Number(b[0]), Number(b[1])]
        if (isImage && img.implicitWidth > 0)
            return [img.implicitWidth / (Number(spec.scale) || 1), img.implicitHeight / (Number(spec.scale) || 1)]
        return [200, 160]
    }
    readonly property var slice: {
        const s = spec.slice
        const out = [0, 0, 0, 0]
        if (s) for (let i = 0; i < 4 && i < s.length; ++i) out[i] = Math.max(0, Number(s[i]) || 0)
        return out
    }
    function withValue(key, value) {
        const next = {}
        for (const k in spec) next[k] = spec[k]
        next[key] = value
        return next
    }
    function setSlice(i, boxValue) {
        const s = slice.slice()
        s[i] = Math.max(0, Math.round(boxValue))
        ed.changed(withValue("slice", s))
    }

    implicitHeight: body.implicitHeight
    Column {
        id: body
        width: parent.width
        spacing: Theme.gap(8)

        // ---- the shape, at the size of its own box ----
        Surface {
            id: frame
            width: parent.width
            height: Theme.sp(170)
            radius: Theme.radiusMd
            role: "input"
            borderWidth: 1
            borderRole: "border"

            readonly property real k: Math.min((width - Theme.sp(24)) / ed.box[0],
                                               (height - Theme.sp(24)) / ed.box[1])
            readonly property real drawW: ed.box[0] * k
            readonly property real drawH: ed.box[1] * k
            readonly property real drawX: (width - drawW) / 2
            readonly property real drawY: (height - drawH) / 2

            Image {   // an image shape is its own picture
                id: img
                x: frame.drawX; y: frame.drawY
                width: frame.drawW; height: frame.drawH
                visible: ed.isImage
                fillMode: Image.Stretch
                source: ed.isImage ? String(ed.spec.image || "") : ""
            }
            Shape {   // ...and a path shape is drawn
                x: frame.drawX; y: frame.drawY
                width: frame.drawW; height: frame.drawH
                visible: !ed.isImage
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: Theme.accent
                    strokeColor: Theme.text
                    strokeWidth: 1
                    scale: Qt.size(frame.k, frame.k)
                    PathSvg { path: ed.isImage ? "" : String(ed.spec.path || "") }
                }
            }
            // What stretches, shaded: the middle band between the guides, on
            // each axis. Everything outside them keeps its size.
            Rectangle {
                x: frame.drawX + ed.slice[0] * frame.k
                width: Math.max(0, frame.drawW - (ed.slice[0] + ed.slice[2]) * frame.k)
                y: frame.drawY; height: frame.drawH
                color: Theme.text; opacity: 0.12
            }
            Rectangle {
                y: frame.drawY + ed.slice[1] * frame.k
                height: Math.max(0, frame.drawH - (ed.slice[1] + ed.slice[3]) * frame.k)
                x: frame.drawX; width: frame.drawW
                color: Theme.text; opacity: 0.12
            }
            // ---- the fixed edges, as guides ----
            Repeater {
                model: [{ i: 0, vertical: true }, { i: 2, vertical: true },
                        { i: 1, vertical: false }, { i: 3, vertical: false }]
                Item {
                    id: guide
                    required property var modelData
                    readonly property bool vertical: modelData.vertical
                    readonly property int side: modelData.i
                    // left and top measure from the start, right and bottom from the end
                    readonly property bool fromEnd: side === 2 || side === 3
                    readonly property real at: {
                        const px = ed.slice[side] * frame.k
                        return vertical ? (fromEnd ? frame.drawX + frame.drawW - px : frame.drawX + px)
                                        : (fromEnd ? frame.drawY + frame.drawH - px : frame.drawY + px)
                    }
                    x: vertical ? at - width / 2 : frame.drawX
                    y: vertical ? frame.drawY : at - height / 2
                    width: vertical ? Theme.ctl(11) : frame.drawW
                    height: vertical ? frame.drawH : Theme.ctl(11)
                    readonly property bool lit: guideMa.containsMouse || guideMa.pressed
                    Rectangle {
                        anchors.centerIn: parent
                        width: guide.vertical ? 1 : parent.width
                        height: guide.vertical ? parent.height : 1
                        color: guide.lit ? Theme.accent : Theme.text
                        opacity: guide.lit ? 1 : 0.55
                    }
                    Rectangle {   // the handle, at the guide's foot
                        anchors.horizontalCenter: guide.vertical ? parent.horizontalCenter : undefined
                        anchors.verticalCenter: guide.vertical ? undefined : parent.verticalCenter
                        x: guide.vertical ? (parent.width - width) / 2 : (guide.side === 3 ? parent.width - width : 0)
                        y: guide.vertical ? (guide.side === 2 ? parent.height - height : 0) : (parent.height - height) / 2
                        width: Theme.ctl(7); height: Theme.ctl(7)
                        radius: width / 2
                        color: guide.lit ? Theme.accent : Theme.text
                    }
                    InkText {   // ...and what it is set to, while it is moved
                        visible: guide.lit
                        x: guide.vertical ? parent.width + Theme.gap(2) : 0
                        y: guide.vertical ? 0 : parent.height + Theme.gap(2)
                        text: Math.round(ed.slice[guide.side]) + ""
                        ink: "accent"
                        font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                    }
                    MouseArea {
                        id: guideMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: guide.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor
                        property real grab: 0
                        onPressed: (m) => { grab = guide.vertical ? m.x : m.y }
                        onPositionChanged: (m) => {
                            if (!pressed || frame.k <= 0) return
                            const pos = guide.vertical ? guide.x + m.x - grab + width / 2
                                                       : guide.y + m.y - grab + height / 2
                            const along = guide.vertical ? (pos - frame.drawX) / frame.k
                                                         : (pos - frame.drawY) / frame.k
                            const span = guide.vertical ? ed.box[0] : ed.box[1]
                            ed.setSlice(guide.side, guide.fromEnd ? span - along : along)
                        }
                    }
                }
            }
        }

        // ---- what the shape is made of ----
        Row {
            width: parent.width
            spacing: Theme.gap(6)
            PushButton {
                label: ed.isImage ? "Choose image" : "Paste path"
                onClicked: ed.isImage ? Portal.openFile("shape-image", "Choose a shape image", "Images",
                                                        ["*.png", "*.webp", "*.svg"], false)
                                      : pathIn.forceActiveFocus()
            }
        }
        Surface {   // the path itself, for a shape written by hand
            width: parent.width
            height: Theme.sp(24) + Theme.inset("input", "top") + Theme.inset("input", "bottom")
            visible: !ed.isImage
            radius: Theme.radiusMd
            role: "button"
            borderWidth: 1
            borderRole: pathIn.activeFocus ? "borderStrong" : "border"
            TextInput {
                id: pathIn
                anchors.fill: parent
                anchors.leftMargin: Theme.inset("input", "left")
                anchors.rightMargin: Theme.inset("input", "right")
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                clip: true
                font { pixelSize: Theme.fs(11); family: "monospace" }
                text: String(ed.spec.path || "")
                onEditingFinished: if (text.trim() !== String(ed.spec.path || "")) ed.changed(ed.withValue("path", text.trim()))
            }
        }
    }
}
