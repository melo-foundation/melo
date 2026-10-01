import QtQuick
import ".."

// The startup splash's picture (src/core/Splash.h): one of the logo looks in
// looks.json, rendered offscreen and painted into the splash window.
Item {
    id: scene
    width: 560; height: 200
    // an entry of looks.json
    property var look: ({ cut: true, parts: {} })
    // true holds the fill clock at 0: the still frame, and the frames before
    // the live picture has settled
    property bool hold: true
    readonly property var parts: look.parts
    readonly property string cut: look.cut ? "-cut" : ""

    Binding { target: Theme; property: "held"; value: scene.hold }
    // the fill clock runs only while something moving is previewed
    Component.onCompleted: Theme.previewing += 1

    Item {
        readonly property real k: Math.min(scene.width * 0.9 / 246, scene.height * 0.9 / 84)
        anchors.centerIn: parent
        width: 246 * k; height: 84 * k
        LogoLayer { anchors.fill: parent; art: "art/lockup-tile" + scene.cut + ".png"; entry: scene.parts.tile || "#ffffff" }
        LogoLayer { anchors.fill: parent; visible: !scene.look.cut; art: "art/lockup-glyph.png"; entry: scene.parts.glyph || "#ffffff" }
        LogoLayer { anchors.fill: parent; art: "art/lockup-wordmark.png"; entry: scene.parts.wordmark || "#ffffff" }
        LogoLayer { anchors.fill: parent; art: "art/lockup-top" + (scene.look.cut ? "-cut" : "-solid") + ".png"; entry: scene.parts.top || "#00000000" }
    }
}
