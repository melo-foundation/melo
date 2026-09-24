import QtQuick
import ".."

// A Text whose colour is an ink ROLE, and which adapts per pixel when the
// theme asks for it. Everything a Text can do still works; `ink` replaces
// `color`.
Text {
    id: root
    property string ink: "text"
    font.family: Theme.fontFamily
    readonly property var inkRole: Theme.inkRole(ink)
    readonly property bool adaptive: inkRole.source === "adaptive"
    readonly property bool styled: Theme.layered(inkRole)
    readonly property bool twin: adaptive || styled || inkRole.blend.length > 0
    readonly property var effect: inkRole.effect
    readonly property bool haloOn: effect !== null && effect.kind !== "off"
    property bool keepTwin: false   // built while hidden: for a label that fades into view (see ScrollText)
    // what an adaptive ink reads; a reader in another window inverts instead
    property Item backdrop: Theme.backdrop
    // what InkTwin asks a host for
    readonly property int labelWrap: wrapMode
    readonly property int labelElide: elide
    readonly property int maxLines: maximumLineCount

    // With a twin the paint stands down but the layout stays (opacity would take the
    // twin with it). A theme's own ink key, named from a bar row, has no Theme
    // property and is resolved through Theme.inkColour.
    color: twin ? "transparent" : (Theme[ink] !== undefined ? Theme[ink] : Theme.inkColour(ink))
    // Qt's 1px style would draw in styleColor regardless of a transparent
    // fill, and would stack under a real halo
    Binding { target: root; property: "style"; value: Text.Normal; when: root.twin || root.haloOn }

    // Nothing is built for a hidden label (`visible` reads through the parent chain).
    // The plain Text is transparent whenever there is a twin, so a label coming back
    // into view never flashes its plain colour.
    // the halo, beneath this Text's own paint and beneath the twin
    Loader {
        z: -1
        active: root.haloOn && (root.visible || root.keepTwin)
        source: "TextHalo.qml"
        onLoaded: {
            item.label = root
            item.inside = true
            item.effect = Qt.binding(() => root.effect)
            item.colour = Qt.binding(() => Theme.inkEffectColour(root.ink))
            item.backdrop = Qt.binding(() => root.backdrop)
        }
    }

    Loader {
        anchors.fill: parent
        active: root.twin && (root.visible || root.keepTwin)
        source: "InkTwin.qml"
        onLoaded: item.host = root
    }
}
