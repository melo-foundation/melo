import QtQuick
import QtQuick.Window
import ".."

// A themed background that is either a colour or a blend mode, per the palette.
// Two items, not one swappable material: only one of BlendRect (C++) and
// Rectangle is visible, and the other costs a node that is never drawn.
Item {
    id: root

    // Name one of Theme.surfaceRoles and the colour, opacity, source, blend and amounts all come from it; the
    // individual properties below stay settable for the few callers that
    // paint something the palette has no role for.
    property string role: ""
    readonly property var r: role.length > 0 ? Theme.role(role) : null

    // The palette colour to paint when this is not a blend.
    property color color: r ? Qt.rgba(r.colour.r, r.colour.g, r.colour.b, r.colour.a * r.opacity)
                            : "transparent"
    // "" for plain alpha-over; otherwise one of BlendRect's modes. This is the
    // MODE axis only — where the colour comes from is `source`.
    property string blend: r ? r.blend : ""
    // The item adaptive samples; defaults to Theme.backdrop (Main's background
    // layer). A hardware blend reads the framebuffer, the shader needs an item.
    property Item backdrop: Theme.backdrop
    // "colour" or "adaptive". Independent of blend: the source fills the
    // surface, the mode decides how that is combined with what is behind it.
    property string source: r ? r.source : "colour"
    // x hue, y luminosity, z saturation, w opacity
    property vector4d adaptiveAmounts: r ? r.amounts : Qt.vector4d(0, -1, 0, 1)

    readonly property bool wantAdaptive: source === "adaptive"
    // Any layer counts, not only the bottom one: a plain colour under a fill
    // is still an entry with a fill in it.
    readonly property bool styled: r !== null ? Theme.layered(r) : Theme.isStyled(source)
    property var styledParams: r ? r.params : Theme.styledOf(null)
    property var styledLayers: r ? r.layers : null
    // The role's own opacity, apart from `color`'s alpha: for a stack that
    // alpha is the bottom layer's, so a styled surface reads the master
    // opacity from here.
    readonly property real fillOpacity: r ? r.opacity : 1
    // A ShaderEffectSource renders nothing for an item in another window, so
    // secondary windows fall back to the hardware inversion instead of a blank surface.
    readonly property bool sameWindow: backdrop !== null
        && backdrop.Window.window === root.Window.window
    readonly property bool adaptive: wantAdaptive && sameWindow
    readonly property string hwMode: blend.length > 0 ? blend
                                   : (wantAdaptive && !adaptive ? "invert" : "normal")
    // Per-corner radii default to -1 (Rectangle's "use radius"); the title bar
    // rounds only its top corners, and a plain radius rounded the header's bottom edge.
    property real radius: 0
    // A border, for the callers whose Rectangle had one. Drawn as a ring over
    // the fill so it sits on top of a blend the same way it sat on a colour.
    property color borderColor: "transparent"
    property real borderWidth: 0
    // A border naming a role takes that role's colour; a fill or contrast role
    // draws the ring as coverage filled like a styled surface. A plain colour keeps
    // Rectangle's border.
    property string borderRole: ""
    readonly property var borderR: borderRole.length > 0 ? Theme.role(borderRole) : null
    readonly property bool borderStyled: borderR !== null
        && (Theme.layered(borderR) || (borderR.source === "adaptive" && sameWindow))
    Binding {
        target: root; property: "borderColor"; when: root.borderRole.length > 0
        value: root.borderR ? Qt.rgba(root.borderR.colour.r, root.borderR.colour.g, root.borderR.colour.b,
                                      root.borderR.colour.a * root.borderR.opacity) : "transparent"
    }
    property real topLeftRadius: -1
    property real topRightRadius: -1
    property real bottomLeftRadius: -1
    property real bottomRightRadius: -1

    readonly property bool blending: blend.length > 0 || wantAdaptive || styled
    // Latches on so a hover does not rebuild a fill: a row flipping `role`
    // between "" and "hover" would otherwise build and tear down the whole chain.
    // Once blended, the chain stays built and hidden at rest (no per-frame cost),
    // and the resting Rectangle stays batchable.
    property bool everBlended: false
    onBlendingChanged: if (blending) everBlended = true
    Component.onCompleted: if (blending) everBlended = true
    // The latch resets on every palette change (Theme.paletteGen), so a flat
    // theme drops the hidden chain.
    readonly property int palGen: Theme.paletteGen
    onPalGenChanged: everBlended = blending

    Rectangle {
        anchors.fill: parent
        // Stays visible behind the fill: a styled fill that draws nothing (a shared
        // corner mask not rendered yet, likely after Refresh) would otherwise be a hole
        // through the window. Costs ~8% of render on a fully styled theme.
        visible: true
        color: root.color
        radius: root.radius
        // Explicit fallback rather than passing -1 through and trusting that
        // Rectangle still reads it as "unset": a corner nobody asked about
        // takes the plain radius.
        topLeftRadius: root.topLeftRadius >= 0 ? root.topLeftRadius : root.radius
        topRightRadius: root.topRightRadius >= 0 ? root.topRightRadius : root.radius
        bottomLeftRadius: root.bottomLeftRadius >= 0 ? root.bottomLeftRadius : root.radius
        bottomRightRadius: root.bottomRightRadius >= 0 ? root.bottomRightRadius : root.radius
    }

    // Melo-module items load by source, only when the role blends: qmltestrunner
    // and the offscreen platform lack BlendRect, so a top-level `import Melo` would
    // fail every component containing a Surface there.
    Loader {
        anchors.fill: parent
        active: root.blending || root.everBlended
        visible: root.blending
        source: "BlendSurface.qml"
        onLoaded: {
            item.host = root
        }
    }

    Loader {
        anchors.fill: parent
        active: root.borderWidth > 0 && root.borderStyled
        sourceComponent: Item {
            Item {
                width: 0; height: 0; clip: true
                Rectangle {
                    id: ring
                    width: root.width; height: root.height
                    layer.enabled: true
                    color: "transparent"
                    radius: root.radius
                    topLeftRadius: root.topLeftRadius >= 0 ? root.topLeftRadius : root.radius
                    topRightRadius: root.topRightRadius >= 0 ? root.topRightRadius : root.radius
                    bottomLeftRadius: root.bottomLeftRadius >= 0 ? root.bottomLeftRadius : root.radius
                    bottomRightRadius: root.bottomRightRadius >= 0 ? root.bottomRightRadius : root.radius
                    border.color: "#ffffff"
                    border.width: root.borderWidth
                }
            }
            StyledFill {
                anchors.fill: parent
                visible: Theme.layered(root.borderR)
                mask: ring
                kind: root.borderR.source
                params: root.borderR.params
                colourA: root.borderR.colour
                layers: root.borderR.layers
                backdrop: root.backdrop
                opacity: root.borderR.opacity
            }
            HueLum {
                anchors.fill: parent
                visible: root.borderR.source === "adaptive"
                backdrop: visible ? root.backdrop : null
                mask: ring
                hue: root.borderR.amounts.x; lum: root.borderR.amounts.y; sat: root.borderR.amounts.z
                opacity: root.borderR.amounts.w * root.borderR.opacity
            }
        }
    }
    Rectangle {
        anchors.fill: parent
        visible: root.borderWidth > 0 && root.borderColor.a > 0 && !root.borderStyled
        color: "transparent"
        radius: root.radius
        topLeftRadius: root.topLeftRadius >= 0 ? root.topLeftRadius : root.radius
        topRightRadius: root.topRightRadius >= 0 ? root.topRightRadius : root.radius
        bottomLeftRadius: root.bottomLeftRadius >= 0 ? root.bottomLeftRadius : root.radius
        bottomRightRadius: root.bottomRightRadius >= 0 ? root.bottomRightRadius : root.radius
        border.color: root.borderColor
        border.width: root.borderWidth
    }
}
