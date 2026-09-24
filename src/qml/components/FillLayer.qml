import QtQuick
import QtQuick.Window
import ".."

// One layer of a stack, as the shader draws it. Shared by the stack renderer (in
// place) and BlendLayer (to a texture, through a hardware mode). Everything from
// the surrounding fill comes through `host`: mask, shared edge field, position in
// the window.
ShaderEffect {
    id: fill
    property Item host: null
    property var modelData: null
    property int index: 0
    // the picture for an image layer, which the host builds one of per layer
    property var picture: null

    visible: lKind !== "adaptive"
    readonly property string lKind: Theme.sourceOf(modelData)
    readonly property var lPrm: Theme.styledOf(modelData)
    readonly property color lCol: Theme.colorOf(modelData, "#ffffff")
    readonly property bool lImage: Theme.fillImage(lKind)
    readonly property string lShader: lImage ? Qt.resolvedUrl("imagefill.frag.qsb") : Theme.fillShader(lKind)
    fragmentShader: lShader.length > 0 ? lShader : Qt.resolvedUrl("styled.frag.qsb")
    blending: true
    property variant mask: host.mask ? host.mask : host.blank
    property variant shapeMap: host.field ? host.field : host.blank
    property vector4d colourA: Qt.vector4d(lCol.r, lCol.g, lCol.b, 1)
    // the palette, six stops at most, and how many there are
    function stopAt(i) {
        const list = lPrm.colours || []
        const c = Theme.colorOf(i < list.length ? list[i] : "#ffffff", "#ffffff")
        return Qt.vector4d(c.r, c.g, c.b, c.a)   // a stop's alpha travels with it
    }
    property vector4d pal0: stopAt(0)
    property vector4d pal1: stopAt(1)
    property vector4d pal2: stopAt(2)
    property vector4d pal3: stopAt(3)
    property vector4d pal4: stopAt(4)
    property vector4d pal5: stopAt(5)
    property real palN: Math.min(6, (lPrm.colours || []).length)
    // What the pattern is anchored to. `local` is the caller's override — a
    // preview shows the whole of a fill in its own box whatever the entry
    // says — and past that the layer chooses: the window, this item, or the
    // content of the scroller this item is in.
    readonly property string space: host.local ? "item" : String(modelData.space || "window")
    // Nine-slice belongs to the actual control, never to a window-sized tile.
    readonly property bool inItem: space === "item" || (lKind === "image" && par2.x === 5)
    property vector4d geo0: inItem ? Qt.vector4d(0, 0, Math.max(1, host.width), Math.max(1, host.height))
                          : space === "scroll" && host.scroller ? host.geoScroll : host.geo0
    // the pattern's unit: this item's own size when the pattern is its own, a
    // fixed 800px otherwise so a resize never rescales a fill
    property vector4d geo1: Qt.vector4d(inItem ? Math.max(1, host.width) : 800,
                                        inItem ? Math.max(1, host.height) : 800,
                                        host.mask ? 1 : 0,
                                        lImage ? (picture && picture.width > 0
                                                  ? picture.height / picture.width : 1)
                                               : Theme.fillIndex(lKind))
    property variant tex: picture && picture.status === Image.Ready ? picture : host.blank
    property vector4d par: Qt.vector4d(host.lineHeightPx, lPrm.scale, lPrm.angle, lPrm.speed)
    // Only imagefill reads this: decoded source pixels and the chosen
    // coordinate space's box, for fitting and fixed-size corner caps.
    property vector4d imageGeometry: Qt.vector4d(
        picture && picture.status === Image.Ready ? picture.width : 0,
        picture && picture.status === Image.Ready ? picture.height : 0,
        inItem ? host.width : space === "scroll" && host.scroller ? host.scroller.contentWidth
                 : host.Window.window ? host.Window.window.width : host.width,
        inItem ? host.height : space === "scroll" && host.scroller ? host.scroller.contentHeight
                 : host.Window.window ? host.Window.window.height : host.height)
    // mode, and how wide the band at the edge is
    property vector4d msk: Qt.vector4d(Math.max(0, Theme.maskModes.indexOf(String(modelData.mask))),
                                       modelData.maskDist !== undefined ? modelData.maskDist : 3,
                                       modelData.phase !== undefined ? modelData.phase : 0, host.fieldReach)
    property real mskSoft: modelData.maskSoft !== undefined ? modelData.maskSoft : 0
    // A kind's own options, eight floats it names itself. The option
    // table says which slot each one takes; a kind that declares none
    // pays for nothing but two zeroed uniforms.
    function ownAt(i) {
        const t = Theme.fillOptions(lKind), o = lPrm.own || ({})
        for (let j = 0; j < t.length; ++j)
            if (t[j].slot === i) return lKind === "image" ? Theme.imageOption(lPrm, t[j].name)
                : parseFloat(o[t[j].name] !== undefined ? o[t[j].name] : t[j].value) || 0
        return 0
    }
    // The shape, when the host knows it is a rounded rectangle: four radii in
    // px, clockwise from the top left. -1 sends the shader to the cached
    // field instead — a glyph, or anything EdgeField had to measure.
    property vector4d rad: host && host.rad ? host.rad : Qt.vector4d(-1, -1, -1, -1)
    property vector4d par2: Qt.vector4d(ownAt(0), ownAt(1), ownAt(2), ownAt(3))
    property vector4d par3: Qt.vector4d(ownAt(4), ownAt(5), ownAt(6), ownAt(7))
    // Only a moving layer binds the clock. One moving palette entry runs the clock,
    // and every bound fill would re-upload a uniform each frame that its shader
    // multiplies by zero speed; even a ternary on the clock is a JS evaluation per
    // layer per frame (96,776 in a four-second drag).
    readonly property bool animated: Theme.fillMoves(lKind, lPrm)
    // The short-circuit drops the dependency on Theme.clock while the host is
    // not visible; a hidden page's fills re-evaluating this every tick measured
    // 78% of binding evaluations at 1000 tracks / 250 albums.
    property real time: animated && host.visible ? Theme.clock : 0
}
