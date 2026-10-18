import QtQuick
import QtQuick.Window
import ".."
import "../components"

// One part of the logo: a palette entry filled through one mask.
Item {
    id: part
    property var entry: "#ffffff"
    property url art: ""
    readonly property var r: Theme.roleOfEntry(entry)

    // the mask is sampled by the fill, never drawn itself
    Item {
        width: 0; height: 0; clip: true
        Image {
            id: shape
            width: part.width; height: part.height
            source: part.art
            smooth: true
            mipmap: true
        }
    }
    StyledFill {
        anchors.fill: parent
        mask: shape
        layers: part.r.layers
        fieldDensity: Screen.devicePixelRatio
    }
}
