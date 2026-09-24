import QtQuick

// Bounded inner distance to the actual coverage, in logical pixels: two
// separable searches find the closest empty pixel (glyph counters included).
// Both layers hold data, not colour, and refresh only when mask or size changes;
// animated materials sample the cached result.
Item {
    id: field
    property Item mask: null
    // how far in the field is measured: 32 unless a layer reads further
    property real reach: 32
    // Half resolution for a surface body: a quarter of the pixels and half the
    // `reach` scan. It turns the half-texel bias below into a whole logical pixel,
    // invisible on a bevel and wrong on a glyph stem, so text and icons keep full
    // resolution.
    property bool coarse: false
    readonly property real ds: coarse ? 0.5 : 1
    // Uniforms are in texels of the target, so `distance / reach` (all either shader
    // writes) is the same at either resolution and decodes to logical pixels.
    // `texels` must be the texture's actual size, rounded the same way, or the
    // shader steps in texels the target does not have.
    readonly property vector2d texels: Qt.vector2d(Math.max(1, Math.round(settledWidth * ds)),
                                                   Math.max(1, Math.round(settledHeight * ds)))
    readonly property real texReach: Math.max(1, reach * ds)
    // Nothing is layered without a size, at any of the three levels. A layer
    // with no size is a render target with nothing in it, grabbed during
    // preprocess inside a pass that is already running.
    readonly property bool sized: width > 0 && height > 0 && mask !== null

    // Not redrawn while the size moves: each drag step would reallocate both passes
    // and re-run the search. Readers sample in uv and stretch the held texture; 100 ms
    // after the last change it reruns at the size that stuck. The held distances
    // stretch too, so a rim reads narrow until then; not corrected.
    // Not Theme.held: it stays true for the whole drag and would also freeze changes
    // to the mask's content (a glyph, a radius).
    property real settledWidth: width
    property real settledHeight: height
    readonly property bool settling: width !== settledWidth || height !== settledHeight
    // The first real size to arrive is taken at once, or the first hundred milliseconds of the window are a
    // held 0x0 texture — nothing at all.
    function resize() {
        if (settledWidth > 0 && settledHeight > 0) settle.restart()
        else { settledWidth = width; settledHeight = height }
    }
    // Once per turn, as BlendSurface's own settle is.
    onWidthChanged: Qt.callLater(resize)
    onHeightChanged: Qt.callLater(resize)
    Component.onCompleted: { settledWidth = width; settledHeight = height; settle.stop() }
    Timer {
        id: settle
        interval: 100
        onTriggered: { field.settledWidth = field.width; field.settledHeight = field.height }
    }

    layer.enabled: sized
    layer.smooth: true
    layer.live: !settling
    // ...at the SETTLED size, like the passes below: a texture size that
    // followed the live one would re-allocate per step of a drag, which is
    // the thing layer.live is holding off.
    layer.textureSize: Qt.size(texels.x, texels.y)

    Item {
        width: 0; height: 0; clip: true
        ShaderEffect {
            id: horizontal
            width: field.settledWidth; height: field.settledHeight
            layer.enabled: field.sized
            layer.smooth: true
            layer.live: !field.settling
            layer.textureSize: Qt.size(field.texels.x, field.texels.y)
            visible: field.sized
            blending: false
            fragmentShader: Qt.resolvedUrl("edgex.frag.qsb")
            property variant src: field.mask
            property vector2d size: field.texels
            property real reach: field.texReach
        }
    }
    ShaderEffect {
        anchors.fill: parent
        blending: false
        visible: field.sized
        fragmentShader: Qt.resolvedUrl("edgey.frag.qsb")
        property variant src: horizontal
        property vector2d size: field.texels
        property real reach: field.texReach
    }
}
