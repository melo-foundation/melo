pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../src/qml/components/plugingrants.js" as PG

// Grant writes from the Plugins tab, where one click can undo another:
//  1. An object rebuilt from a row is stale until pluginsChanged returns and
//     writes back fields the user did not touch, so each patch carries one key.
//  2. The Repeater's model is a JS array, so any plugin's refresh recreates
//     every delegate and wipes row-local in-flight state; test_z_ pins that,
//     and the grant path keeps none.
//
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml
Item {
    id: root

    // shaped like sidecar PluginInfo, trimmed to what the grant rows read
    function plugin(id, grants) {
        return { id: id, name: id, capabilities: ["ui"],
                 permissions: { rawNetwork: true, intercept: ["play", "seek"] },
                 // The sidecar's permissionWarnings copy verbatim, so a
                 // reworded warning cannot drift from the fixture and silently
                 // show nothing.
                 warnings: ["Runs code inside melo, and can reach the network from its own interface.",
                            "Network access is not limited to the sites it lists.",
                            "Handles play instead of melo."],
                 grants: grants }
    }

    // the Plugins tab's own model shape: a plain JS array, reassigned wholesale
    // on every pluginsChanged
    property var pluginList: [plugin("a", { ui: false, rawNetwork: false, intercept: [] }),
                              plugin("b", { ui: false, rawNetwork: false, intercept: [] })]
    property int rowBuilds: 0
    Repeater {
        id: rows
        model: root.pluginList
        Item {
            required property var modelData
            Component.onCompleted: root.rowBuilds++
        }
    }

    TestCase {
        name: "PluginGrants"

        function keys(o) {
            const ks = []
            for (const k in o) ks.push(k)
            ks.sort()
            return ks
        }

        // A ui click must not carry rawNetwork/intercept: those values are the
        // ones a concurrent click has already moved on the server.
        function test_a_ui_patch_is_one_key() {
            const p = root.plugin("a", { ui: false, rawNetwork: true, intercept: ["play"] })
            compare(keys(PG.patch(p, "ui", true)), ["ui"])
            compare(PG.patch(p, "ui", true).ui, true)
            compare(PG.patch(p, "ui", false).ui, false)
        }

        function test_b_rawnetwork_patch_is_one_key() {
            const p = root.plugin("a", { ui: true, rawNetwork: false, intercept: ["play"] })
            compare(keys(PG.patch(p, "rawNetwork", true)), ["rawNetwork"])
            compare(PG.patch(p, "rawNetwork", true).rawNetwork, true)
            compare(PG.patch(p, "rawNetwork", false).rawNetwork, false)
        }

        // The server replaces the intercept array wholesale, so this one patch
        // IS a list — but only this plugin's list plus/minus this click.
        function test_c_intercept_patch_carries_only_this_action() {
            const p = root.plugin("a", { ui: true, rawNetwork: true, intercept: ["play"] })
            const add = PG.patch(p, "intercept", true, "seek")
            compare(keys(add), ["intercept"])
            compare(add.intercept, ["play", "seek"])

            const drop = PG.patch(p, "intercept", false, "play")
            compare(drop.intercept, [])

            // idempotent: an on-click for an already-granted action adds nothing,
            // an off-click for an ungranted one removes nothing
            compare(PG.patch(p, "intercept", true, "play").intercept, ["play"])
            compare(PG.patch(p, "intercept", false, "seek").intercept, ["play"])
        }

        // patch() is read-only on its input: a mutated intercept array would
        // desync the row's checked binding from the sidecar's answer.
        function test_d_patch_does_not_mutate_the_plugin() {
            const p = root.plugin("a", { ui: false, rawNetwork: false, intercept: ["play"] })
            PG.patch(p, "intercept", true, "seek")
            PG.patch(p, "intercept", false, "play")
            compare(p.grants.intercept, ["play"])
        }

        // A corrupt/absent grants bag must read as "nothing granted" rather
        // than throwing inside a binding.
        function test_e_missing_or_nonarray_grants_read_as_empty() {
            const bad = [undefined, {}, { intercept: "play" }, { intercept: 7 }, { intercept: null }]
            for (let i = 0; i < bad.length; i++) {
                const p = root.plugin("a", bad[i])
                compare(PG.checked(p, "intercept", "play"), false, "case " + i)
                compare(PG.checked(p, "ui"), false, "case " + i)
                compare(PG.patch(p, "intercept", true, "play").intercept, ["play"], "case " + i)
            }
        }

        // No shared state: interleaving two plugins' clicks leaves each patch
        // derived from its own PluginInfo.
        function test_f_one_plugins_click_cannot_move_another() {
            const a = root.plugin("a", { ui: false, rawNetwork: false, intercept: ["play"] })
            const b = root.plugin("b", { ui: true, rawNetwork: false, intercept: [] })

            const a1 = PG.patch(a, "intercept", true, "seek")
            const b1 = PG.patch(b, "ui", false)
            const b2 = PG.patch(b, "intercept", true, "play")
            const a2 = PG.patch(a, "ui", true)

            compare(a1.intercept, ["play", "seek"])
            compare(keys(b1), ["ui"])
            compare(b2.intercept, ["play"])     // b's empty list, not a's
            compare(keys(a2), ["ui"])
            compare(a.grants.intercept, ["play"])
            compare(b.grants.intercept, [])
        }

        // Rows come from capabilities/permissions; ⚠ copy comes from the
        // sidecar's warnings, never invented here.
        function test_g_rows_and_warning_copy() {
            const p = root.plugin("a", { ui: false, rawNetwork: false, intercept: [] })
            const rs = PG.rows(p)
            compare(rs.length, 3)
            compare(rs[0].kind, "rawNetwork")
            compare(rs[1].action, "play")
            compare(rs[2].action, "seek")
            compare(PG.warning(p, "ui"),
                    "⚠ Runs code inside melo, and can reach the network from its own interface.")
            compare(PG.warning(p, "rawNetwork"),
                    "⚠ Network access is not limited to the sites it lists.")
            compare(PG.warning(p, "intercept", "play"), "⚠ Handles play instead of melo.")
            compare(PG.warning(p, "intercept", "seek"), "")   // no sidecar line, no copy
            compare(PG.rows(undefined).length, 0)

            const plain = { id: "c", capabilities: [], permissions: {}, grants: {} }
            compare(PG.rows(plain).length, 0)
        }

        // An error plugin that is already on must still be clickable so the
        // user can turn it off. Turning an invalid plugin on is refused.
        // Production change that would make this fail: `enabled: state !== "error"`.
        function test_h_error_plugin_can_be_turned_off() {
            compare(PG.enableToggleEnabled({ state: "running", enabled: true }), true)
            compare(PG.enableToggleEnabled({ state: "stopped", enabled: false }), true)
            compare(PG.enableToggleEnabled({ state: "crashed", enabled: true }), true)
            compare(PG.enableToggleEnabled({ state: "error", enabled: true }), true)
            compare(PG.enableToggleEnabled({ state: "error", enabled: false }), false)
            compare(PG.enableToggleEnabled(undefined), false)
        }

        // Why there is no busy flag on the row: this is a refresh for plugin
        // "a" only, and it still destroys plugin "b"'s delegate.
        function test_z_row_local_state_cannot_survive_a_refresh() {
            compare(rows.count, 2)
            compare(root.rowBuilds, 2)
            const bRow = rows.itemAt(1)

            // only plugin "a"'s grants moved, exactly as one setGrants reply looks
            root.pluginList = [root.plugin("a", { ui: true, rawNetwork: false, intercept: [] }),
                               root.plugin("b", { ui: false, rawNetwork: false, intercept: [] })]

            compare(root.rowBuilds, 4, "every row was rebuilt, including untouched \"b\"")
            verify(rows.itemAt(1) !== bRow,
                   "row objects are new, so any state held on a row is gone with them")
        }
    }
}
