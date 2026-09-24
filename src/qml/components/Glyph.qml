import QtQuick
import QtQuick.Shapes

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
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        // scaling is about (0,0), so a glyph fitted smaller than its box would
        // sit in the top-left corner of it; put its centre back in the middle
        transform: [ Scale { xScale: g.k; yScale: g.k },
                     Translate { x: g.size / 2 - g.vb / 2 * g.k
                                 y: g.size / 2 - g.vb / 2 * g.k } ]

        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 0 ? g.p[0] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 1 ? g.p[1] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 2 ? g.p[2] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 3 ? g.p[3] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 4 ? g.p[4] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 5 ? g.p[5] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 6 ? g.p[6] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 7 ? g.p[7] : "" } }
        ShapePath { strokeColor: g.strokeC; strokeWidth: g.sw; fillColor: g.fillC
                    capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                    PathSvg { path: g.p.length > 8 ? g.p[8] : "" } }
    }
}
