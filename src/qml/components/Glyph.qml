import QtQuick
import QtQuick.Shapes
import QtQuick.Window

// The drawing of an icon, on its own: the paths of a named glyph at a size
// in a colour. Icon draws itself with one, and its halo draws copies of one
// — a component cannot hold an instance of itself, so the drawing lives
// here and Icon is the reader of the theme around it.
Item {
    id: g
    property string name
    property color color: "#aaaaaa"
    property real size: 14
    property real strokeWidth: 2
    property var glyphs: ({})
    width: size; height: size
    readonly property var spec: glyphs[name] ?? { fill: false, paths: [] }
    readonly property var p: spec.paths
    readonly property color fillC: spec.fill ? color : "transparent"
    readonly property color strokeC: spec.fill ? "transparent" : color
    readonly property real vb: spec.vb ?? 24
    readonly property real swRaw: spec.sw ?? strokeWidth
    // `fit` scales each glyph so its ink (measured per glyph, in its own units) is the
    // same fraction of the box; unfitted, an eq draws 71% wider than a play at the
    // same `size` and rows move when their icons change. `inkFill` is the one
    // tunable. The stroke is divided back out so it does not thin as a glyph shrinks.
    readonly property real inkFill: 0.75          // 18 of a 24 box
    readonly property real ink: spec.ink ?? vb
    readonly property real inkSw: spec.fill ? 0 : swRaw
    readonly property real fit: ink > inkSw ? (inkFill * vb - inkSw) / (ink - inkSw) : 1
    readonly property real sw: swRaw / fit
    readonly property real k: size / vb * fit
    // A glyph of only horizontal and vertical lines is drawn on the pixel grid at a
    // whole-pixel width, or its lines come out different weights (a 2-unit line at
    // 16 px is 1.33 px wide). Null when any path is not such a line.
    readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property int lineDev: spec.fill ? 0 : Math.max(1, Math.round(sw * k * dpr))
    readonly property var hinted: hintPaths(p, k, size / 2 - vb / 2 * k, dpr, lineDev)
    function hintPaths(paths, k, t, d, n) {
        if (!paths || paths.length === 0) return null
        // Rounded outward from the glyph's centre, so lines the same distance from it
        // stay the same distance apart. A stroke's centre sits mid-pixel for an odd
        // width and on a pixel edge otherwise; a fill's edges sit on pixel edges.
        const c = size / 2 * d
        const c0 = n % 2 ? Math.floor(c) + 0.5 : Math.round(c)
        const snap = (v) => {
            const off = (v * k + t) * d - c
            return (c0 + Math.sign(off) * Math.round(Math.abs(off))) / d
        }
        const out = []
        for (const path of paths) {
            const tok = path.match(/[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?/g)
            if (!tok) return null
            let cmd = "", x = 0, y = 0, sx = 0, sy = 0, s = ""
            for (let i = 0; i < tok.length;) {
                if (/[A-Za-z]/.test(tok[i])) cmd = tok[i++]
                if (cmd === "Z") {
                    if (i < tok.length && !/[A-Za-z]/.test(tok[i])) return null
                    s += "Z"; x = sx; y = sy; continue
                }
                let nx = x, ny = y
                if (cmd === "M" || cmd === "L") { nx = +tok[i++]; ny = +tok[i++] }
                else if (cmd === "H") nx = +tok[i++]
                else if (cmd === "V") ny = +tok[i++]
                else return null
                if (isNaN(nx) || isNaN(ny)) return null
                if (cmd === "L" && nx !== x && ny !== y) return null   // diagonal
                s += (cmd === "M" ? "M" : "L") + snap(nx) + " " + snap(ny)
                if (cmd === "M") { sx = nx; sy = ny; cmd = "L" }
                x = nx; y = ny
            }
            out.push(s)
        }
        return out
    }
    readonly property var drawn: hinted ?? p
    readonly property real drawnSw: hinted ? lineDev / dpr : sw
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        // scaling is about (0,0), so a glyph fitted smaller than its box would
        // sit in the top-left corner of it; put its centre back in the middle
        transform: [ Scale { xScale: g.hinted ? 1 : g.k; yScale: g.hinted ? 1 : g.k },
                     Translate { x: g.hinted ? 0 : g.size / 2 - g.vb / 2 * g.k
                                 y: g.hinted ? 0 : g.size / 2 - g.vb / 2 * g.k } ]

        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 0 ? g.drawn[0] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 1 ? g.drawn[1] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 2 ? g.drawn[2] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 3 ? g.drawn[3] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 4 ? g.drawn[4] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 5 ? g.drawn[5] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 6 ? g.drawn[6] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 7 ? g.drawn[7] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.drawnSw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.drawn.length > 8 ? g.drawn[8] : "" } }
    }
}
