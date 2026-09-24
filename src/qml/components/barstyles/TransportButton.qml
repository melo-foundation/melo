import QtQuick
import ".."
import "../.."

// One of the transport's three (previous, play, next) as an element of
// its own, and play as a disc on the accent when a document says so.
Item {
    id: tbtn
    property string which: "play"        // prev play next
    property bool disc: false            // play on a solid disc
    // Disc face by role; `<role>Hover` is the hover face. Small buttons take a
    // role of their own because a rim that reads on a 33px disc disappears at 24px.
    property string role: "accent"
    readonly property string discRole: tbtn.hovered ? tbtn.role + "Hover" : tbtn.role
    property int size: Theme.ctl(28)
    property int glyphSize: Math.round(size * 0.62)
    readonly property bool play: which === "play"
    readonly property string glyph: play ? (PlayerState.isPlaying ? "pause" : "play") : which
    readonly property bool enabled_: PlayerState.hasTrack
    // What this button IS, said once. The glyph name is melo's own
    // vocabulary; a screen reader needs English.
    readonly property string a11yName: which === "prev" ? "Previous track"
                                     : which === "next" ? "Next track"
                                     : PlayerState.isPlaying ? "Pause" : "Play"
    // Play outgrows its neighbours by a share of their size; prev/next discs stay
    // the size asked for since they sit level with play. pillW/pillH make a capsule
    // (e.g. 35 x 13 seek buttons); the disc rounds to the shorter side.
    property real pillW: 0
    property real pillH: 0
    implicitWidth: pillW > 0 ? pillW : play && disc ? size + Math.round(size * 0.28) : size
    implicitHeight: pillH > 0 ? pillH : implicitWidth
    // Keyboard and screen-reader access.
    activeFocusOnTab: enabled_
    Accessible.role: Accessible.Button
    Accessible.name: tbtn.a11yName
    Accessible.description: tbtn.a11yName
    Accessible.onPressAction: if (tbtn.enabled_) tbtn.press()
    Keys.onPressed: (e) => {
        if (!tbtn.enabled_) return
        if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { tbtn.press(); e.accepted = true }
    }
    function press() {
        if (which === "prev") Player.previous()
        else if (which === "next") Player.next()
        else Player.togglePlay()
    }
    // With no track the transport takes
    // no hover, no press face and no sink: a button that reacts promises a
    // click that does nothing.
    readonly property bool hovered: enabled_ && bma.containsMouse
    readonly property bool held: enabled_ && bma.pressed
    Surface {
        anchors.fill: parent
        radius: Math.min(width, height) / 2
        visible: tbtn.disc
        role: tbtn.discRole
    }
    IconButton {
        id: glyphBtn
        objectName: "transportButton"
        anchors.centerIn: parent
        name: tbtn.glyph
        size: tbtn.disc ? tbtn.glyphSize + 2 : tbtn.glyphSize
        // The ink the theme puts on its accent: the palette decides what reads
        // on it, and the players this disc comes from draw a dark glyph on a
        // pale glass face.
        ink: tbtn.disc ? "textOnAccent"
           : !tbtn.enabled_ ? "controlOff" : (tbtn.hovered ? "controlHover" : "control")
        color: Theme[ink]
        // A disc is already a face. Framing one would put a square button
        // under the circle; a button without a disc takes the frame.
        framed: Theme.transportButtons === "button" && !tbtn.disc
        hovered: tbtn.hovered
        pressed: tbtn.held
        frameWidth: tbtn.size   // the transport sizes its own buttons
    }
    MouseArea {
        id: bma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: if (tbtn.enabled_) tbtn.press()
    }
}
