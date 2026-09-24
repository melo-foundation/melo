import QtQuick

// Text filled with the backdrop's colours, hue and luminosity moved by two
// continuous amounts. Coverage uses BlendText's zero-sized clip, but the shader
// reads the backdrop as a texture, so hue and lightness move separately, which
// per-channel hardware blending cannot do. backdrop must be an item melo drew;
// the desktop behind the window belongs to the compositor.
Item {
    id: root

    property Item backdrop
    property string text: ""
    property font font
    property int horizontalAlignment: Text.AlignLeft
    property int verticalAlignment: Text.AlignTop
    property real lineHeight: 1.0
    property int wrapMode: Text.NoWrap
    property int maximumLineCount: 1
    property int elide: Text.ElideNone

    // -1..1 each. hue: a full turn of the wheel at the ends. sat: -1 grey,
    // 1 doubled. lum: negative inverts, positive flips away from mid-grey —
    // inverting is symmetric about 0.5, so it cannot separate anything from a
    // mid-tone backdrop, and flipping always can.
    property real hue: 0
    property real lum: 0
    property real sat: 0

    implicitWidth: glyphs.implicitWidth
    implicitHeight: glyphs.implicitHeight

    Item {
        width: 0; height: 0; clip: true
        Text {
            id: glyphs
            width: root.width
            height: root.height
            text: root.text
            font: root.font
            color: "#ffffff"          // coverage only; the shader supplies colour
            horizontalAlignment: root.horizontalAlignment
            verticalAlignment: root.verticalAlignment
            lineHeight: root.lineHeight
            lineHeightMode: Text.ProportionalHeight
            wrapMode: root.wrapMode
            maximumLineCount: root.maximumLineCount
            elide: root.elide
            layer.enabled: true
        }
    }

    HueLum {
        anchors.fill: parent
        backdrop: root.backdrop
        mask: glyphs
        hue: root.hue
        lum: root.lum
        sat: root.sat
    }
}
