import QtQuick
import QtTest
import "../../src/qml/components/shortcuts.js" as SC

Item {
    id: rootItem
    width: 200; height: 200

    property int fired: 0
    property int ctrlFired: 0

    Shortcut { sequence: SC.toQt("KeyN"); onActivated: rootItem.fired++ }
    Shortcut { sequence: SC.toQt("ctrl+KeyF"); onActivated: rootItem.ctrlFired++ }

    TestCase {
        name: "Shortcuts"
        when: windowShown

        function test_conversions() {
            compare(SC.toQt("ctrl+KeyF"), "Ctrl+F")
            compare(SC.toQt("Space"), "Space")
            compare(SC.toQt("ArrowLeft"), "Left")
            compare(SC.toQt("KeyN"), "N")
            compare(SC.toQt("shift+Delete"), "Shift+Del")
            compare(SC.toQt("ctrl+shift+KeyL"), "Ctrl+Shift+L")
            compare(SC.toQt("BracketRight"), "]")
            compare(SC.toQt("Backspace"), "Backspace")
            compare(SC.format("ctrl+KeyF"), "Ctrl + F")
            compare(SC.format("ArrowRight"), "→")
        }

        function test_merged_defaults() {
            const m = SC.merged(null)
            compare(m.playPause, "Space")
            compare(m.toggleCompact, "")
            compare(m.toggleMaximize, "")
            const m2 = SC.merged({ playPause: "KeyX" })
            compare(m2.playPause, "KeyX")
            compare(m2.nextTrack, "KeyN")
            compare(m2.toggleCompact, "")
        }

        function test_merged_keeps_plugin_ids() {
            const m = SC.merged({ playPause: "KeyX", "winamp.toggleGroup": "KeyW" })
            compare(m.playPause, "KeyX")
            compare(m["winamp.toggleGroup"], "KeyW")
            compare(m.nextTrack, "KeyN")
            const empty = SC.merged({ "winamp.toggleGroup": "" })
            compare(empty.hasOwnProperty("winamp.toggleGroup"), false)
        }

        function test_compact_maximize_listed() {
            compare(SC.DEFAULTS.toggleCompact, "")
            compare(SC.DEFAULTS.toggleMaximize, "")
            compare(SC.ORDER.indexOf("toggleCompact") >= 0, true)
            compare(SC.ORDER.indexOf("toggleMaximize") >= 0, true)
            compare(SC.LABELS.toggleCompact.length > 0, true)
            compare(SC.LABELS.toggleMaximize.length > 0, true)
        }

        function test_record_shifted_keys() {
            // Shift+key reports the SHIFTED symbol; recorder must normalize
            compare(SC.fromKeyEvent({ key: Qt.Key_Delete, modifiers: Qt.ShiftModifier }),
                    "shift+Delete")
            compare(SC.fromKeyEvent({ key: Qt.Key_L,
                        modifiers: Qt.ControlModifier | Qt.ShiftModifier }),
                    "ctrl+shift+KeyL")
            compare(SC.fromKeyEvent({ key: Qt.Key_Exclam, modifiers: Qt.ShiftModifier }),
                    "shift+Digit1")
            // some deliveries omit the modifier when the symbol encodes it
            compare(SC.fromKeyEvent({ key: Qt.Key_Exclam, modifiers: 0 }),
                    "shift+Digit1")
            compare(SC.fromKeyEvent({ key: Qt.Key_BraceRight, modifiers: Qt.ShiftModifier }),
                    "shift+BracketRight")
            compare(SC.fromKeyEvent({ key: Qt.Key_N, modifiers: 0 }), "KeyN")
            // bare modifier press records nothing
            compare(SC.fromKeyEvent({ key: Qt.Key_Shift, modifiers: Qt.ShiftModifier }), null)
        }

        function test_shortcut_fires() {
            rootItem.fired = 0
            keyClick(Qt.Key_N)
            compare(rootItem.fired, 1, "bare-key shortcut fires")
            keyClick(Qt.Key_F, Qt.ControlModifier)
            compare(rootItem.ctrlFired, 1, "modified shortcut fires")
        }
    }
}
