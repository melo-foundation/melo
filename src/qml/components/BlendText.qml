import QtQuick
import Melo 1.0

// Text that blends with whatever is behind it. Qt's glyph materials allow no
// pipeline-state change, so blended text goes through a texture. A source only has
// a texture if it renders (layer.enabled at opacity 0, a hidden
// ShaderEffectSource and layer.effect all hand over nothing), but a rendering
// source also draws, and the blend then acts on its own pixels. A zero-sized clip
// gives both: the text renders and its drawing is clipped away (tst_blendmodes).
// blend: "" is plain Text; any other value costs one offscreen texture this size.
Item {
    id: root

    property string text: ""
    property font font
    property color color: "#ffffff"
    property int horizontalAlignment: Text.AlignLeft
    property int wrapMode: Text.NoWrap
    property int maximumLineCount: 1
    property int elide: Text.ElideNone
    property real lineHeight: 1.0
    // "" for ordinary text; otherwise one of BlendRect's modes.
    property string blend: ""
    // Chrome the plain path keeps: a legibility halo when it is not blending.
    property int textStyle: Text.Normal
    property color textStyleColor: "transparent"

    readonly property bool blending: blend.length > 0

    implicitWidth: measure.implicitWidth
    implicitHeight: measure.implicitHeight

    // The ordinary path. Identical to having written a Text here.
    Text {
        id: measure
        anchors.fill: parent
        visible: !root.blending
        text: root.text
        font: root.font
        color: root.color
        horizontalAlignment: root.horizontalAlignment
        wrapMode: root.wrapMode
        maximumLineCount: root.maximumLineCount
        elide: root.elide
        lineHeight: root.lineHeight
        lineHeightMode: Text.ProportionalHeight
        style: root.textStyle
        styleColor: root.textStyleColor
    }

    // The blended path's source: rendered, and drawn nowhere.
    Item {
        width: 0
        height: 0
        clip: true
        visible: root.blending
        Text {
            id: mask
            width: root.width
            height: root.height
            text: root.text
            font: root.font
            // WHITE, not root.color. This is a coverage mask — the blend
            // decides what the words look like, and a coloured mask would
            // tint the result twice.
            color: "#ffffff"
            horizontalAlignment: root.horizontalAlignment
            wrapMode: root.wrapMode
            maximumLineCount: root.maximumLineCount
            elide: root.elide
            lineHeight: root.lineHeight
            lineHeightMode: Text.ProportionalHeight
            layer.enabled: root.blending
        }
    }

    BlendRect {
        anchors.fill: parent
        visible: root.blending
        source: root.blending ? mask : null
        mode: root.blending ? root.blend : "normal"
        color: root.color
        // the layer is coverage, not a picture: its RGB carries the glyphs'
        // subpixel-antialiasing fringes, and reading it as colour makes every
        // blended word soft and orange-edged
        maskOnly: true
    }
}
