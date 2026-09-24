import QtQuick
import QtQuick.Window
import ".."

// The effect an entry asks for, drawn beneath what it decorates (an ink's words
// or a surface's rounded rectangle). `shape` is a Component drawing that thing in
// place, filled with `parent.tint`; the thing itself is never touched or layered,
// so words stay sharp.
//
//   outline        one white copy in a texture, dilated round a ring of radius
//                  size by halodilate.frag, enough taps to close it
//   hard shadow    one copy, offset
//   glow, soft     one hidden copy, blurred Skia-style (downsample so half a
//   shadow         sigma is about a texel, then separable Gaussian) and cut at
//                  0.5*erfc(1/sqrt2), exactly one sigma out
Item {
    id: halo
    // the shape, and how big a size unit is for it (an ink: 6% of the
    // font's pixel size; a surface: 2px)
    property Component shape: null
    property real unit: 1
    property var effect: null          // Theme.effectOf(...)
    property color colour: "#000000"   // resolved: a colour, or adapted
    // what an ADAPTIVE halo colour reads. With one in this window the halo
    // is drawn as coverage and filled per pixel from it, exactly as adaptive
    // words are; without one `colour` is the flat fallback, adapted once
    // against the ink.
    property Item backdrop: null
    readonly property bool adaptiveHalo: on && Theme.sourceOf(effect.colour) === "adaptive"
                                         && backdrop !== null && backdrop.Window.window === halo.Window.window
    readonly property vector4d amounts: on ? Theme.adaptiveOf(effect.colour) : Qt.vector4d(0, 0, 0, 1)
    // a styled effect colour fills the same coverage from styled.frag
    readonly property bool styledHalo: on && Theme.isStyled(Theme.sourceOf(effect.colour))
    readonly property bool masked: adaptiveHalo || styledHalo
    z: -1
    readonly property bool on: shape !== null && effect !== null && effect.kind !== "off" && effect.size > 0
    readonly property bool ring: on && effect.kind === "outline"
    readonly property bool hardShadow: on && effect.kind === "shadow" && effect.soft < 0.05
    readonly property bool blurred: on && !ring && !hardShadow
    // Relative to the type. size, dx and dy are in units of 6% of the font's
    // pixel size: 1 is a hairline on a 12px row and a real 3px stroke on a
    // 52px title, and one theme setting looks right on both. A flat pixel
    // count would be invisible on one and a slab on the other.
    readonly property real px: on ? effect.size * unit : 0
    readonly property real dx: on && effect.kind === "shadow" ? effect.dx * unit : 0
    readonly property real dy: on && effect.kind === "shadow" ? effect.dy * unit : 0
    readonly property int copies: ring ? Math.min(64, Math.max(8, Math.ceil(2 * Math.PI * px * 1.2))) : 0
    // the caller places and sizes this over the thing it decorates
    visible: on
    // how far the paint can reach past the label: the ring, a shadow's
    // offset, or a blur's three sigma. The mask layer has to hold all of it.
    readonly property real pad: on ? Math.ceil(px * 4 + Math.max(Math.abs(dx), Math.abs(dy)) + 5) : 0

    // The paint, in a box the size of the reach. Drawn straight to the
    // window when the colour is flat; when adaptive the box is a zero-sized
    // clip (rendered for its layer, never seen) and the HueLum below fills
    // its coverage from the backdrop.
    Item {
        x: -halo.pad; y: -halo.pad
        width: 0; height: 0
        clip: halo.masked
        Item {
            id: paint
            width: halo.width + 2 * halo.pad
            height: halo.height + 2 * halo.pad
            layer.enabled: halo.masked
            Item {
                id: origin
                x: halo.pad; y: halo.pad
                width: halo.width; height: halo.height

    // A clone: the shape, at the halo's size, filled with a tint. White when
    // the coverage is what is wanted (a masked halo), the colour otherwise.
    component Clone: Item {
        property color tint: halo.masked ? "#ffffff" : halo.colour
        width: halo.width; height: halo.height
        Loader { anchors.fill: parent; sourceComponent: halo.shape
                 property color tint: parent.tint }
    }

            // outline: one white copy of the words in a texture padded by
            // the radius, dilated round the ring by halodilate.frag
            Loader {
                active: halo.ring
                sourceComponent: Item {
                    id: ringBox
                    readonly property real rp: Math.ceil(halo.px) + 1
                    x: -rp; y: -rp
                    width: halo.width + 2 * rp; height: halo.height + 2 * rp
                    // At a fractional scale the box's device rect is fractional, so sample points
                    // sit off texel centres and the ring's taps round unevenly, weighting the
                    // outline to one side. The shader snaps the sample point to the texel grid.
                    readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
                    readonly property size texSize: Qt.size(Math.max(1, Math.ceil(width * dpr)), Math.max(1, Math.ceil(height * dpr)))
                    Item {
                        width: 0; height: 0; clip: true
                        Item {
                            id: ringGlyphs
                            width: ringBox.width; height: ringBox.height
                            layer.enabled: true; layer.smooth: true
                            layer.textureSize: ringBox.texSize
                            Clone { x: ringBox.rp; y: ringBox.rp; tint: "#ffffff" }
                        }
                    }
                    ShaderEffect {
                        anchors.fill: parent
                        fragmentShader: Qt.resolvedUrl("halodilate.frag.qsb")
                        blending: true
                        property variant src: ringGlyphs
                        property vector2d texSize: Qt.vector2d(ringBox.texSize.width, ringBox.texSize.height)
                        property vector2d ringStep: Qt.vector2d(halo.px / ringBox.width, halo.px / ringBox.height)
                        property real taps: halo.copies
                        property real inner: halo.effect.soft >= 0.05 ? 1 : 0
                        property real outerA: halo.effect.soft >= 0.05 ? 1 - 0.6 * halo.effect.soft : 1
                        property vector4d colourV: halo.masked ? Qt.vector4d(1, 1, 1, halo.effect.opacity)
                                                 : Qt.vector4d(halo.colour.r, halo.colour.g, halo.colour.b,
                                                               halo.effect.opacity)
                    }
                }
            }

            // hard shadow: the words again, once, moved
            Loader {
                active: halo.hardShadow
                sourceComponent: Clone { x: halo.dx; y: halo.dy; opacity: halo.effect.opacity }
            }

            Loader {
                active: halo.blurred
                sourceComponent: Item {
                    id: wide
                    readonly property real sigma: Math.max(0.5, halo.px)
                    // The blur's 13 taps at half a sigma only work while that is about one texel;
                    // beyond it they skip texels and stripe the halo. So the words are rendered
                    // scaled down by k, blurred, and the cut draws them back at full size,
                    // bilinear.
                    readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
                    readonly property real k: Math.max(1, Math.floor(sigma * dpr / 2))
                    readonly property real sigmaK: sigma / k
                    readonly property real reachK: Math.ceil(sigmaK * 3 + 1)
                    readonly property real smallW: Math.max(1, halo.width / k)
                    readonly property real smallH: Math.max(1, halo.height / k)
                    Item {
                        width: 0; height: 0; clip: true
                        Item {
                            id: words
                            width: wide.smallW; height: wide.smallH
                            layer.enabled: true; layer.smooth: true
                            Clone { scale: 1 / wide.k; transformOrigin: Item.TopLeft }
                        }
                        ShaderEffect {
                            id: passH
                            x: -wide.reachK; y: 0
                            width: wide.smallW + 2 * wide.reachK; height: wide.smallH
                            layer.enabled: true; layer.smooth: true
                            fragmentShader: Qt.resolvedUrl("haloblur.frag.qsb")
                            property variant src: words
                            property vector4d map: Qt.vector4d(width / wide.smallW, 1, -wide.reachK / wide.smallW, 0)
                            property vector2d tapStep: Qt.vector2d(wide.sigmaK * 0.5 / wide.smallW, 0)
                        }
                        ShaderEffect {
                            id: passV
                            x: passH.x; y: -wide.reachK
                            width: passH.width; height: wide.smallH + 2 * wide.reachK
                            layer.enabled: true; layer.smooth: true
                            fragmentShader: Qt.resolvedUrl("haloblur.frag.qsb")
                            property variant src: passH
                            property vector4d map: Qt.vector4d(1, height / wide.smallH, 0, -wide.reachK / wide.smallH)
                            property vector2d tapStep: Qt.vector2d(0, wide.sigmaK * 0.5 / wide.smallH)
                        }
                    }
                    // the cut, at full size: the blurred field scaled back up by k
                    ShaderEffect {
                        x: passV.x * wide.k + halo.dx; y: passV.y * wide.k + halo.dy
                        width: passV.width * wide.k; height: passV.height * wide.k
                        fragmentShader: Qt.resolvedUrl("halocut.frag.qsb")
                        blending: true
                        property variant src: passV
                        readonly property real centre: 0.159
                        readonly property real half: halo.effect.kind === "glow"
                            ? 0.159 : Math.max(0.01, halo.effect.soft * 0.14 + 0.01)
                        property real lo: Math.max(0.0, centre - half)
                        property real hi: Math.min(1.0, centre + half)
                        property vector4d colourV: halo.masked ? Qt.vector4d(1, 1, 1, halo.effect.opacity)
                                                 : Qt.vector4d(halo.colour.r, halo.colour.g, halo.colour.b,
                                                               halo.effect.opacity)
                    }
                }
            }
            }
        }
    }
    // Built only once the coverage layer is on: a fill that binds its sampler before
    // `paint` is a texture provider stays on an empty texture.
    Loader {
        x: -halo.pad; y: -halo.pad
        width: paint.width; height: paint.height
        active: halo.masked
        sourceComponent: Item {
            StyledFill {
                id: styledReader
                anchors.fill: parent
                visible: halo.styledHalo
                kind: halo.styledHalo ? Theme.sourceOf(halo.effect.colour) : "rainbow"
                params: Theme.styledOf(halo.on ? halo.effect.colour : null)
                colourA: halo.on ? Theme.colorOf(halo.effect.colour, "#ffffff") : "#ffffff"
                opacity: halo.on ? halo.effect.opacity : 1
            }
            HueLum {
                id: adaptiveReader
                anchors.fill: parent
                visible: halo.adaptiveHalo
                backdrop: halo.adaptiveHalo ? halo.backdrop : null
                hue: halo.amounts.x
                lum: halo.amounts.y
                sat: halo.amounts.z
                opacity: halo.amounts.w
            }
            Component.onCompleted: { styledReader.mask = paint; adaptiveReader.mask = paint }
        }
    }
}
