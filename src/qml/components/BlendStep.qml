import QtQuick
import ".."

// One rung of the stack: `below` (everything under this layer) and `above` (the
// layer) blended and composited; the next rung takes the result as its `below`.
// Built only for modes the GPU's blend factors cannot do (see StyledFill).
ShaderEffect {
    id: step
    property Item below: null      // null for the bottom rung: nothing under it
    property Item above: null
    property Item blank: null      // a texture to bind when there is no backdrop
    property int mode: 0
    property real amount: 1        // the layer's own opacity
    // A filter rung: no fill of its own, the layers under it changed instead.
    // What it needs beyond a blend is what a fill's shader needs for its mask
    // mode — the coverage, the distance field — and its own options.
    property int filter: 0
    property Item maskItem: null
    property Item field: null
    property vector4d msk: Qt.vector4d(0, 3, 0, 0)
    property vector4d par2: Qt.vector4d(0, 0, 0, 0)
    property vector4d par3: Qt.vector4d(0, 0, 0, 0)

    fragmentShader: Qt.resolvedUrl("stackblend.frag.qsb")
    blending: true
    property variant belowTex: below ? below : blank
    property variant aboveTex: above ? above : blank
    property variant mask: maskItem ? maskItem : blank
    property variant shapeMap: field ? field : blank
    property vector4d par: Qt.vector4d(mode, below ? 1 : 0, amount, filter)
    property vector4d geo: Qt.vector4d(Math.max(1, width), Math.max(1, height), maskItem ? 1 : 0, 0)
}
