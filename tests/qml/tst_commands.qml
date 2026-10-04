pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../src/qml/components/commands.js" as CMD

// Gesture occupancy helper for the Shortcuts tab. One occupant per gesture and
// one gesture per command, so a row's label is the binding.
//
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_commands.qml
Item {
    TestCase {
        name: "Commands"

        function keys(o) {
            const ks = []
            for (const k in o) ks.push(k)
            ks.sort()
            return ks
        }

        function test_assigning_steals() {
            const n = CMD.applyGesture({}, "playerBar.doubleClick", "winamp.toggleGroup")
            compare(n["playerBar.doubleClick"], "winamp.toggleGroup")
            compare(CMD.occupant(n, "titleBar.doubleClick"), "toggleMaximize")
        }

        // Moving a command to another gesture unbinds the one it held by default,
        // so the row shows the new gesture.
        function test_moving_a_command_leaves_its_default_gesture() {
            const n = CMD.applyGesture({}, "titleBar.doubleClick", "toggleCompact")
            compare(n["titleBar.doubleClick"], "toggleCompact")
            compare(n["playerBar.doubleClick"], CMD.NONE)
            compare(CMD.gestureLabel(n, "toggleCompact"), "Title bar double-click")
            compare(CMD.gestureLabel(n, "toggleMaximize"), "\u2014")
        }

        // A gesture the command took from another goes back to that owner.
        function test_moving_back_returns_the_borrowed_gesture() {
            const a = CMD.applyGesture({}, "titleBar.doubleClick", "toggleCompact")
            const b = CMD.applyGesture(a, "playerBar.doubleClick", "toggleCompact")
            compare(b["playerBar.doubleClick"], "toggleCompact")
            compare(b.hasOwnProperty("titleBar.doubleClick"), false)
            compare(CMD.occupant(b, "titleBar.doubleClick"), "toggleMaximize")
            compare(CMD.gestureLabel(b, "toggleCompact"), "Player bar double-click")
        }

        function test_clear_deletes_key_not_empty_string() {
            const g = { "playerBar.doubleClick": "winamp.toggleGroup" }
            const n = CMD.applyGesture(g, "playerBar.doubleClick", "")
            compare(n.hasOwnProperty("playerBar.doubleClick"), false)
            compare(keys(n), [])
        }

        function test_falsy_commandId_deletes_key() {
            const g = { "titleBar.doubleClick": "toggleMaximize" }
            const n = CMD.applyGesture(g, "titleBar.doubleClick", null)
            compare(n.hasOwnProperty("titleBar.doubleClick"), false)
            compare(keys(n), [])
        }

        function test_gesture_catalog() {
            compare(CMD.GESTURES, ["playerBar.doubleClick", "titleBar.doubleClick"])
            compare(CMD.LABELS["playerBar.doubleClick"], "Player bar double-click")
            compare(CMD.LABELS["titleBar.doubleClick"], "Title bar double-click")
            compare(CMD.GESTURE_DEFAULTS["playerBar.doubleClick"], "toggleCompact")
            compare(CMD.GESTURE_DEFAULTS["titleBar.doubleClick"], "toggleMaximize")
        }

        function test_default_returns_the_command_to_its_gesture() {
            const a = CMD.applyGesture({}, "titleBar.doubleClick", "toggleCompact")
            const n = CMD.defaultGestures(a, "toggleCompact")
            compare(n["playerBar.doubleClick"], "toggleCompact")
            compare(CMD.occupant(n, "titleBar.doubleClick"), "toggleMaximize")
        }

        // Clearing UNBINDS. Handing the gesture back to its default occupant
        // would leave no way to say "nothing", and a deleted key reads as
        // "nobody has said anything", which falls back to the default too.
        function test_clear_occupants_unbinds_rather_than_handing_back() {
            const g = { "playerBar.doubleClick": "winamp.toggleGroup" }
            const n = CMD.clearOccupants(g, "winamp.toggleGroup")
            compare(n["playerBar.doubleClick"], CMD.NONE)
            compare(n.hasOwnProperty("titleBar.doubleClick"), false)   // not this command's
        }

        function test_gesture_label_names_the_gesture_a_command_holds() {
            compare(CMD.gestureLabel({}, "toggleCompact"), "Player bar double-click")
            compare(CMD.gestureLabel(CMD.clearOccupants({}, "toggleCompact"), "toggleCompact"), "\u2014")
            compare(CMD.gestureLabel({}, "playPause"), "\u2014")
        }

        function test_clearing_unbinds_default_gestures_too() {
            const n = CMD.clearOccupants({}, "toggleCompact")
            compare(n["playerBar.doubleClick"], CMD.NONE)
            compare(n.hasOwnProperty("titleBar.doubleClick"), false)   // not this command's
        }

        function test_has_gesture_default_only_for_catalog_occupants() {
            compare(CMD.hasGestureDefault("toggleCompact"), true)
            compare(CMD.hasGestureDefault("toggleMaximize"), true)
            compare(CMD.hasGestureDefault("playPause"), false)
            compare(CMD.hasGestureDefault("winamp.toggleGroup"), false)
        }

        function test_command_rows_include_plugin_commands() {
            const order = ["playPause", "toggleCompact"]
            const labels = { playPause: "Play / Pause", toggleCompact: "Mini player" }
            const plugins = [
                { id: "winamp", commands: [
                    { id: "toggleGroup", label: "Show / hide Winamp" },
                    { id: "toggleMain", label: "Winamp: main window" }] },
                { id: "silent", commands: [] },
                { id: "none" },
            ]
            const rows = CMD.commandRows(order, labels, plugins)
            compare(rows.length, 4)
            compare(rows[0].id, "playPause")
            compare(rows[0].label, "Play / Pause")
            compare(rows[1].id, "toggleCompact")
            compare(rows[2].id, "winamp.toggleGroup")
            compare(rows[2].label, "Show / hide Winamp")
            compare(rows[3].id, "winamp.toggleMain")
            compare(rows[3].label, "Winamp: main window")
        }

        // Plugin ⚙ page: hijack is a setting, not a list-row. toggleGroup
        // is the show/hide command; other plugins with no such command get
        // no toggle. Off gives the gesture back to toggleCompact.
        function test_playerbar_hijack_is_toggleGroup_only() {
            const winamp = { id: "winamp", commands: [
                { id: "toggleGroup", label: "Show / hide Winamp" },
                { id: "toggleMain", label: "Winamp: main window" }] }
            compare(CMD.hijackCommandId(winamp), "winamp.toggleGroup")
            compare(CMD.hijackCommandId({ id: "src", commands: [] }), "")
            compare(CMD.hijackCommandId(undefined), "")
        }

        function test_playerbar_hijack_on_steals_only_that_gesture() {
            const p = { id: "winamp", commands: [{ id: "toggleGroup" }] }
            const n = CMD.setPlayerBarHijack({}, p, true)
            compare(n["playerBar.doubleClick"], "winamp.toggleGroup")
            compare(CMD.occupant(n, "titleBar.doubleClick"), "toggleMaximize")
            compare(CMD.playerBarHijacked(n, p), true)
        }

        function test_playerbar_hijack_off_restores_compact() {
            const p = { id: "winamp", commands: [{ id: "toggleGroup" }] }
            const g = { "playerBar.doubleClick": "winamp.toggleGroup" }
            const n = CMD.setPlayerBarHijack(g, p, false)
            compare(n["playerBar.doubleClick"], "toggleCompact")
            compare(CMD.playerBarHijacked(n, p), false)
        }

        function test_playerbar_hijack_off_does_not_steal_another_occupant() {
            const p = { id: "winamp", commands: [{ id: "toggleGroup" }] }
            const g = { "playerBar.doubleClick": "other.show" }
            const n = CMD.setPlayerBarHijack(g, p, false)
            compare(n["playerBar.doubleClick"], "other.show")
        }
    }
}
