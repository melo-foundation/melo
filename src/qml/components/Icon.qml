import QtQuick
import ".."

// Glyph renderer: Theme's SVG paths (24x24 viewBox) via QtQuick.Shapes.
// NB: ShapePath cannot be created by a Repeater (not an Item) — glyphs use
// up to 9 static path slots; unused slots hold an empty path.
Item {
    id: root
    property string name
    // The ink, by role. Set it and the colour comes from the theme, and when
    // that ink is a fill or contrast the glyph is drawn through it: the shape
    // rendered white as coverage, filled the way words are. A caller may set
    // `color` instead, and gets a colour and nothing else.
    property string ink: ""
    readonly property var inkRole: ink.length > 0 ? Theme.inkRole(ink) : null
    // The twin draws what the plain glyph cannot: a fill, a stack (even of plain
    // colours; `source` is only the bottom layer's), contrast, or an opacity, which
    // overlapping glyph paths would compound and the fill applies once.
    readonly property bool twin: inkRole !== null
                                 && (Theme.layered(inkRole) || inkRole.source === "adaptive"
                                     || inkRole.opacity < 0.999 || inkRole.colour.a < 0.999)
    property color color: ink.length > 0 ? Theme[ink] : "#aaaaaa"
    property real size: Theme.glyph(14)
    property real strokeWidth: 2    // stroke glyphs only

    width: size
    height: size

    // The table is the theme's, so a theme can put its own glyph in one's
    // place; Theme.glyphTable is the built-ins under the overrides.
    readonly property var glyphs: Theme.glyphTable


    // The glyph, drawn plainly when its colour is a colour.
    Glyph {
        anchors.fill: parent
        visible: !root.twin
        name: root.name; color: root.color; size: root.size; strokeWidth: root.strokeWidth
        glyphs: root.glyphs
    }
    // The twin for a fill or contrast ink: the glyph rendered white into a layer
    // behind a zero-sized clip, the fill reading its coverage. One Loader builds both
    // so the layer exists when the fill binds its sampler. Nothing is built for a
    // hidden icon (`visible` reads through the parent chain); the Loader is
    // synchronous, so an icon coming back into view never shows the plain glyph.
    Loader {
        anchors.fill: parent
        active: root.twin && root.visible
        sourceComponent: Item {
            Item {
                width: 0; height: 0; clip: true
                Item {
                    id: coverage
                    width: root.width; height: root.height
                    layer.enabled: true; layer.smooth: true
                    Glyph {
                        anchors.fill: parent
                        name: root.name; color: "#ffffff"; size: root.size; strokeWidth: root.strokeWidth
                        glyphs: root.glyphs
                    }
                }
            }
            StyledFill {
                anchors.fill: parent
                visible: root.inkRole.source !== "adaptive"
                mask: coverage
                kind: root.inkRole.source
                params: root.inkRole.params
                colourA: root.inkRole.colour
                layers: root.inkRole.layers
                opacity: root.inkRole.opacity
                // A glyph sizes like text: the shape-aware kinds size their edge
                // and their ink detail from the line height of text, so an
                // icon hands over its own size and draws as words that tall
                // would — not as a surface the size of its box.
                lineHeightPx: root.size
            }
            HueLum {
                anchors.fill: parent
                visible: root.inkRole.source === "adaptive"
                backdrop: visible ? Theme.backdrop : null
                mask: coverage
                hue: root.inkRole.amounts.x
                lum: root.inkRole.amounts.y
                sat: root.inkRole.amounts.z
                opacity: root.inkRole.amounts.w * root.inkRole.opacity
            }
        }
    }
    // The ink's effect, beneath the glyph: Halo with this glyph as the shape,
    // the same halo the words get. Loaded by source: an icon with no effect
    // — most of them — builds nothing.
    readonly property bool haloOn: inkRole !== null && inkRole.effect.kind !== "off" && inkRole.effect.size > 0
    Loader {
        z: -1
        active: root.haloOn && root.visible
        source: "Halo.qml"
        onLoaded: {
            item.width = Qt.binding(() => root.width)
            item.height = Qt.binding(() => root.height)
            item.unit = Qt.binding(() => root.size * 0.06)
            item.shape = glyphShape
            item.effect = Qt.binding(() => root.inkRole.effect)
            item.colour = Qt.binding(() => Theme.inkEffectColour(root.ink))
            item.backdrop = Qt.binding(() => Theme.backdrop)
        }
    }
    Component {
        id: glyphShape
        Glyph { name: root.name; size: root.size; strokeWidth: root.strokeWidth; glyphs: root.glyphs
                color: parent.tint }
    }
}
