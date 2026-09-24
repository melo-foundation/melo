import QtQuick
import Melo 1.0
import ".."

// One layer of a stack drawn through a hardware blend mode (multiply, screen,
// darken, lighten, subtract).
// The layer is rendered again inside a zero-sized clip, so it produces a texture
// but draws nowhere, and BlendRect puts that texture down at the same z; a hidden
// source hands over an empty texture (see BlendItem).
// Its own file because it needs the Melo module, which qmltestrunner and the
// offscreen platform lack; loaded by source only for a layer that names a mode.
Item {
    id: bl
    property Item host: null
    property var entry: null
    property var picture: null
    property string mode: "normal"

    Item {
        width: 0; height: 0; clip: true
        FillLayer {
            id: src
            width: bl.width; height: bl.height
            host: bl.host
            modelData: bl.entry
            picture: bl.picture
            layer.enabled: true
            opacity: (bl.entry && bl.entry.opacity !== undefined ? bl.entry.opacity : 1) * lCol.a
        }
    }
    BlendRect {
        anchors.fill: parent
        source: src
        mode: bl.mode
        // white is the identity: the tint is already in the layer's own pixels
        color: "#ffffff"
    }
}
