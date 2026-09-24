import QtQuick
import ".."

// Indeterminate progress: a three-quarter arc turning on the spot. The canvas
// paints once — the spin is a transform, not a repaint.
Item {
    id: root
    property bool running: true
    property color color: Theme.textFaint
    implicitWidth: 16
    implicitHeight: 16
    visible: running

    Canvas {
        id: ring
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const w = Math.max(1.5, Math.min(width, height) / 8)
            const r = Math.min(width, height) / 2 - w / 2
            if (r <= 0) return
            ctx.lineWidth = w
            ctx.lineCap = "round"
            ctx.strokeStyle = root.color
            ctx.beginPath()
            ctx.arc(width / 2, height / 2, r, -Math.PI / 2, Math.PI, false)
            ctx.stroke()
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: root; function onColorChanged() { ring.requestPaint() } }
        RotationAnimator on rotation {
            running: root.running
            from: 0; to: 360; duration: 900; loops: Animation.Infinite
        }
    }
}
