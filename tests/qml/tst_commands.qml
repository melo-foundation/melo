pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../src/qml/components/commands.js" as CMD

// Gesture occupancy helper for the Shortcuts tab. One occupant per gesture;
// assigning playerBar.doubleClick must not take compact.escape with it.
// Restore writes that gesture's GESTURE_DEFAULTS occupant (never unbound "").
// Default writes the target map once so toggleCompact keeps both compact gestures.
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
            const g = { "playerBar.doubleClick": "toggleCompact",
                        "compact.escape": "toggleCompact" }
            const n = CMD.applyGesture(g, "playerBar.doubleClick", "winamp.toggleGroup")
            compare(n["playerBar.doubleClick"], "winamp.toggleGroup")
            compare(n["compact.escape"], "toggleCompact")
        }

        // A command that already sits on compact.escape must not take
        // playerBar.doubleClick when that assign is reapplied (or when the
        // helper strips this command's other keys — playerBar stays on
        // toggleCompact).
        function test_occupying_escape_does_not_steal_playerbar() {
            const g = { "playerBar.doubleClick": "toggleCompact",
                        "compact.escape": "winamp.toggleGroup" }
            const n = CMD.applyGesture(g, "compact.escape", "winamp.toggleGroup")
            compare(n["compact.escape"], "winamp.toggleGroup")
            compare(n["playerBar.doubleClick"], "toggleCompact")
        }

        function test_clear_deletes_key_not_empty_string() {
            const g = { "playerBar.doubleClick": "winamp.toggleGroup",
                        "compact.escape": "toggleCompact" }
            const n = CMD.applyGesture(g, "playerBar.doubleClick", "")
            compare(n.hasOwnProperty("playerBar.doubleClick"), false)
            compare(n["playerBar.doubleClick"], undefined)
            compare(n["compact.escape"], "toggleCompact")
            compare(keys(n), ["compact.escape"])
        }

        function test_falsy_commandId_deletes_key() {
            const g = { "titleBar.doubleClick": "toggleMaximize" }
            const n = CMD.applyGesture(g, "titleBar.doubleClick", null)
            compare(n.hasOwnProperty("titleBar.doubleClick"), false)
            compare(keys(n), [])
        }

        function test_gesture_catalog_matches_task1() {
            compare(CMD.GESTURES, ["playerBar.doubleClick",
                                   "compact.escape",
                                   "titleBar.doubleClick"])
            compare(CMD.LABELS["playerBar.doubleClick"], "Player bar double-click")
            compare(CMD.LABELS["compact.escape"], "Escape in compact")
            compare(CMD.LABELS["titleBar.doubleClick"], "Title bar double-click")
            compare(CMD.GESTURE_DEFAULTS["playerBar.doubleClick"], "toggleCompact")
            compare(CMD.GESTURE_DEFAULTS["compact.escape"], "toggleCompact")
            compare(CMD.GESTURE_DEFAULTS["titleBar.doubleClick"], "toggleMaximize")
        }

        // Sequential applyGesture for the same command strips earlier keys
        // (occupancy). Default must write the target map once so both
        // compact occupants persist.
        function test_default_on_toggleCompact_persists_both_gestures() {
            const g = { "playerBar.doubleClick": "winamp.toggleGroup" }
            const n = CMD.defaultGestures(g, "toggleCompact")
            compare(n["playerBar.doubleClick"], "toggleCompact")
            compare(n["compact.escape"], "toggleCompact")
        }

        // Clearing UNBINDS. Handing the gesture back to its default occupant
        // would leave no way to say "nothing", and a deleted key reads as
        // "nobody has said anything", which falls back to the default too.
        // So the answer has to be written down.
        function test_clear_occupants_unbinds_rather_than_handing_back() {
            const g = { "playerBar.doubleClick": "winamp.toggleGroup",
                        "compact.escape": "toggleCompact" }
            const n = CMD.clearOccupants(g, "winamp.toggleGroup")
            compare(n.hasOwnProperty("playerBar.doubleClick"), true)
            compare(n["playerBar.doubleClick"], CMD.NONE)
            compare(n["compact.escape"], "toggleCompact")   // not this command's
        }

        function test_has_gesture_default_only_for_catalog_occupants() {
            compare(CMD.hasGestureDefault("toggleCompact"), true)
            compare(CMD.hasGestureDefault("toggleMaximize"), true)
            compare(CMD.hasGestureDefault("playPause"), false)
            compare(CMD.hasGestureDefault("winamp.toggleGroup"), false)
        }

        function test_command_rows_include_plugin_commands() {
            const order = ["playPause", "toggleCompact"]
            const labels = { playPause: "Play / Pause", toggleCompact: "Compact mode" }
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
        // no toggle. Off restores compact without stripping compact.escape.
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
            const g = { "playerBar.doubleClick": "toggleCompact",
                        "compact.escape": "toggleCompact" }
            const n = CMD.setPlayerBarHijack(g, p, true)
            compare(n["playerBar.doubleClick"], "winamp.toggleGroup")
            compare(n["compact.escape"], "toggleCompact")
            compare(CMD.playerBarHijacked(n, p), true)
        }

        function test_playerbar_hijack_off_restores_compact_keeps_escape() {
            const p = { id: "winamp", commands: [{ id: "toggleGroup" }] }
            const g = { "playerBar.doubleClick": "winamp.toggleGroup",
                        "compact.escape": "toggleCompact" }
            const n = CMD.setPlayerBarHijack(g, p, false)
            compare(n["playerBar.doubleClick"], "toggleCompact")
            compare(n["compact.escape"], "toggleCompact")
            compare(CMD.playerBarHijacked(n, p), false)
        }

        function test_playerbar_hijack_off_does_not_steal_another_occupant() {
            const p = { id: "winamp", commands: [{ id: "toggleGroup" }] }
            const g = { "playerBar.doubleClick": "other.show",
                        "compact.escape": "toggleCompact" }
            const n = CMD.setPlayerBarHijack(g, p, false)
            compare(n["playerBar.doubleClick"], "other.show")
        }
    }
}
