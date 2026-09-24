import QtQuick
import ".."

// Window border: concentric bands drawn inward from this item's outer
// rectangle (or the window's shape), one depth per side; the bordered content
// sits inset by the four depths. All plain-colour bands share one pass of
// bordermask.frag; a fill or gradient band takes its own. Widths snap to device
// pixels, or a fractional scale draws a sliver of the neighbouring colour.
Item {
    id: wb
    property real borderLeft: 0
    property real borderTop: 0
    property real borderRight: 0
    property real borderBottom: 0
    // the outer corners, clockwise from the top left
    property real radiusTL: 0
    property real radiusTR: 0
    property real radiusBR: 0
    property real radiusBL: 0
    // THE BANDS, outermost first: { width, colour } or { width, role }. The
    // theme's, or the three the line settings describe — see Theme.frameBands.
    property var bands: Theme.frameBands
    // A title bar in the border, at the top inside it: how tall, and how much
    // of the frame runs up beside it. What the border frames starts below it.
    property real titleHeight: 0
    property real titleRim: 0
    property bool titleFade: false
    // The window's shape (a WindowShape): its outer edge is the shape's
    // distance field instead of the rounded box, when this border goes round
    // the whole window
    property Item shape: null
    readonly property bool shaped: shape !== null && shape.hasShape === true
    property Item backdrop: Theme.backdrop
    // How soft the frame's two own edges are, in px: the outer one at the
    // window's rim, the inner one where it gives way to what it frames
    property real softOuter: Theme.borderSoftOuter
    property real softInner: Theme.borderSoftInner
    // ...how soft the edges between the bands are, and the shape of the two
    // fades above: "linear", "smooth" or "glow"
    property real softBands: Theme.borderSoftBands
    property string softCurve: Theme.borderSoftCurve

    // A side is never deeper than the bands: past their total there is nothing
    // left to draw, and what the frame goes round would stand off its edge
    readonly property real bl: borderLeft > 0 ? Math.min(GridUi.snap(borderLeft), depth) : 0
    readonly property real bt: borderTop > 0 ? Math.min(GridUi.snap(borderTop), depth) : 0
    readonly property real br: borderRight > 0 ? Math.min(GridUi.snap(borderRight), depth) : 0
    readonly property real bb: borderBottom > 0 ? Math.min(GridUi.snap(borderBottom), depth) : 0
    // nothing is drawn where no side has any depth — a maximised window
    readonly property bool anySide: bl > 0 || bt > 0 || br > 0 || bb > 0

    // the bands as the shader takes them: at most eight, snapped, and where
    // each one ends measured from the outer edge
    readonly property var list: (bands || []).slice(0, 8)
    readonly property var ends: {
        const out = []
        let at = 0
        for (const b of list) { at += Math.max(0, GridUi.snap(Number(b.width) || 0)); out.push(at) }
        return out
    }
    readonly property real depth: ends.length ? ends[ends.length - 1] : 0
    // a band's role, resolved, or null when it is a plain colour of its own
    // A band's colour is an entry, as a palette colour is: a plain colour, or
    // a fill of its own, or the name of a role it follows
    function roleOf(b) {
        if (!b) return null
        if (b.role) return Theme.role(String(b.role))
        if (b.colour && typeof b.colour === "object") return Theme.roleOfEntry(b.colour)
        return null
    }
    function colourOf(b) {
        if (!b) return Qt.rgba(0, 0, 0, 0)
        const r = roleOf(b)
        if (r) return Qt.rgba(r.colour.r, r.colour.g, r.colour.b, r.colour.a * r.opacity)
        return Qt.color(b.colour || "#00000000")
    }
    // a band the plain pass cannot paint: a fill, an adaptive role, or a
    // gradient that spans the frame
    function ownPass(b) {
        const r = roleOf(b)
        if (!r) return false
        if (r.source === "adaptive" || Theme.layered(r)) return true
        return r.source === "gradient" && fitOf(r) > 0.5
    }
    function paramsOf(r) { return (r && r.params) || ({}) }
    function fitOf(r) {
        const p = paramsOf(r)
        return Number((p.own && p.own.fit !== undefined) ? p.own.fit : p.fit) || 0
    }
    function vec4Of(c) { return Qt.vector4d(c.r, c.g, c.b, c.a) }

    component Cover: ShaderEffect {
        width: wb.width; height: wb.height
        fragmentShader: Qt.resolvedUrl("bordermask.frag.qsb")
        property vector2d size: Qt.vector2d(Math.max(1, wb.width), Math.max(1, wb.height))
        property vector4d radii: Qt.vector4d(wb.radiusTL, wb.radiusTR, wb.radiusBR, wb.radiusBL)
        property vector4d insets: Qt.vector4d(wb.bl, wb.bt, wb.br, wb.bb)
        property real region: -1
        property real dpr: GridUi.dpr
        property vector4d tint: Qt.vector4d(1, 1, 1, 1)
        property vector4d stop1: Qt.vector4d(0, 0, 0, 0)
        property vector4d stop2: Qt.vector4d(0, 0, 0, 0)
        property vector4d stop3: Qt.vector4d(0, 0, 0, 0)
        property vector4d stop4: Qt.vector4d(0, 0, 0, 0)
        property real stops: 0
        property real alongEdge: 0
        property real titleH: wb.titleHeight
        property real titleRim: wb.titleRim > 0 ? GridUi.snap(wb.titleRim) : 0
        property real titleFade: wb.titleFade ? 1 : 0
        property vector2d dir: Qt.vector2d(1, 0)
        property real bandsFlat: 0
        property real bandN: wb.ends.length
        property vector4d edges0: Qt.vector4d(wb.ends[0] || 0, wb.ends[1] || 0, wb.ends[2] || 0, wb.ends[3] || 0)
        property vector4d edges1: Qt.vector4d(wb.ends[4] || 0, wb.ends[5] || 0, wb.ends[6] || 0, wb.ends[7] || 0)
        // a band drawn its own way is transparent to the plain pass
        property vector4d col0: wb.plainAt(0)
        property vector4d col1: wb.plainAt(1)
        property vector4d col2: wb.plainAt(2)
        property vector4d col3: wb.plainAt(3)
        property vector4d col4: wb.plainAt(4)
        property vector4d col5: wb.plainAt(5)
        property vector4d col6: wb.plainAt(6)
        property vector4d col7: wb.plainAt(7)
        property real useShape: wb.shaped ? 1 : 0
        property vector2d shapeBox: wb.shaped ? Qt.vector2d(wb.shape.fieldBox.width, wb.shape.fieldBox.height) : Qt.vector2d(1, 1)
        // The field's own slices, which a shape measured at the window's size
        // does not have: then the field is the window, one to one
        property vector4d shapeSlice: wb.shaped ? Qt.vector4d(wb.shape.fieldSlices.x, wb.shape.fieldSlices.y,
                                                              wb.shape.fieldSlices.width, wb.shape.fieldSlices.height)
                                                : Qt.vector4d(0, 0, 0, 0)
        property vector2d fieldSize: wb.shaped ? Qt.vector2d(Math.max(1, wb.shape.fieldSize.width), Math.max(1, wb.shape.fieldSize.height))
                                               : Qt.vector2d(1, 1)
        property real shapeCrop: wb.shaped && wb.shape.cropFit ? 1 : 0
        property real softOut: wb.softOuter
        property real softIn: wb.softInner
        property real softBands: wb.softBands
        property real softCurve: wb.softCurve === "glow" ? 2 : wb.softCurve === "linear" ? 0 : 1
        property variant field: wb.shaped ? wb.shape : blankField
    }
    function plainAt(i) {
        const b = list[i]
        if (!b || ownPass(b)) return Qt.vector4d(0, 0, 0, 0)
        return vec4Of(colourOf(b))
    }
    // a texture to bind when there is no shape: every declared sampler binds
    Item { width: 0; height: 0; clip: true
           Image { id: blankField; source: Theme.blankTex } }

    // Every plain band, in one pass
    Cover { visible: wb.depth > 0 && wb.anySide; region: -1 }

    // ...and a pass each for the bands that need their own arithmetic
    Repeater {
        model: wb.list.length
        Item {
            id: reg
            required property int index
            readonly property var band: wb.list[index]
            readonly property var r: wb.roleOf(band)
            readonly property bool own: wb.ownPass(band)
            readonly property var prm: wb.paramsOf(r)
            readonly property real fit: wb.fitOf(r)
            // a gradient spanning the frame is painted by the shader itself
            readonly property bool ramp: own && r && r.source === "gradient" && r.layers.length === 1 && fit > 0.5
            readonly property var cols: ramp ? (prm.colours || []).slice(0, 4) : []
            function stopVec(i) {
                if (i >= cols.length) return Qt.vector4d(0, 0, 0, 0)
                const c = Qt.color(cols[i])
                return Qt.vector4d(c.r, c.g, c.b, c.a * r.opacity)
            }
            anchors.fill: parent
            visible: own && wb.depth > 0 && wb.anySide
            Cover {
                visible: reg.ramp
                region: reg.index
                tint: wb.vec4Of(wb.colourOf(reg.band))
                stop1: reg.stopVec(0); stop2: reg.stopVec(1); stop3: reg.stopVec(2); stop4: reg.stopVec(3)
                stops: reg.cols.length
                bandsFlat: reg.fit > 1.5 ? 1 : 0
                // a band one pixel deep has no across to speak of: its
                // gradient runs round the edge instead
                alongEdge: reg.index === 0 || reg.index === wb.list.length - 1 ? 1 : 0
                dir: Qt.vector2d(Math.cos(Number(reg.prm.angle || 0) * Math.PI / 180),
                                 Math.sin(Number(reg.prm.angle || 0) * Math.PI / 180))
            }
            // The coverage for a fill, and the fill reading it, built together:
            // a layer switched on by a binding after the fill bound its sampler
            // left the sampler on an empty texture, so a fill or an adaptive
            // border drew nothing. The coverage renders where it is not drawn.
            Loader {
                anchors.fill: parent
                active: reg.own && !reg.ramp && reg.visible
                sourceComponent: Item {
                    Item {
                        width: 0; height: 0; clip: true
                        Cover { id: cover; region: reg.index; layer.enabled: true }
                    }
                    StyledFill {
                        anchors.fill: parent
                        visible: reg.r.source !== "adaptive"
                        mask: cover
                        kind: reg.r.source
                        params: reg.r.params
                        colourA: reg.r.colour
                        layers: reg.r.layers
                        backdrop: wb.backdrop
                        opacity: reg.r.opacity
                    }
                    HueLum {
                        anchors.fill: parent
                        visible: reg.r.source === "adaptive"
                        backdrop: visible ? wb.backdrop : null
                        mask: cover
                        hue: reg.r.amounts.x; lum: reg.r.amounts.y; sat: reg.r.amounts.z
                        opacity: reg.r.amounts.w * reg.r.opacity
                    }
                }
            }
        }
    }
}
