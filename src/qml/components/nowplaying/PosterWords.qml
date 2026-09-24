import QtQuick
import ".."
import "../.."

// Lyrics on a full-bleed photograph. A stripe across the middle takes just
// enough of the picture to read off: the top and the bottom stay whole, which
// is where the poster keeps its title anyway. (Words down one side is the
// record stop's layout.)
Item {
    id: root
    property var np
    property real titleTop: height        // where the poster's own title starts

    Rectangle {
        id: stripe
        x: 0
        y: root.height * 0.22
        width: root.width
        height: root.height * 0.52
        // The stripe takes the text's contrast colour, so it is dark under
        // light text and light under dark text. A fixed black stripe fails
        // every light palette.
        readonly property color ink: Theme.textContrast
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(stripe.ink.r, stripe.ink.g, stripe.ink.b, 0) }
            GradientStop { position: 0.14; color: Qt.rgba(stripe.ink.r, stripe.ink.g, stripe.ink.b, 0.8) }
            GradientStop { position: 0.86; color: Qt.rgba(stripe.ink.r, stripe.ink.g, stripe.ink.b, 0.8) }
            GradientStop { position: 1.0; color: Qt.rgba(stripe.ink.r, stripe.ink.g, stripe.ink.b, 0) }
        }
    }

    NpWords {
        np: root.np
        x: (root.width - width) / 2
        y: root.height * 0.30
        width: Math.min(root.width - 120, 620)
        height: root.height * 0.36
        fontSize: 19
        align: Text.AlignHCenter
        // NpWords defaults these to the theme's text colours; overriding them
        // makes the lyrics ignore the palette. No halo: the stripe above is the
        // ground these read against.
    }
}
