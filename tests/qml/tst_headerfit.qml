import QtQuick
import QtTest
import "../../src/qml"

Item {
    TestCase {
        name: "HeaderFit"
        property var saved: ({})
        function init() {
            saved = Object.assign({}, Theme.ts)
            Theme.ts.header = "combined"
            Theme.ts.uiScale = 1
            Theme.ts.fontScale = 1
            Theme.ts.controlScale = 1
            Theme.ts.spacingScale = 1
            Theme.ts.font = "Red Hat Display"
            Theme.ts.insets = ({ header: { left: 12, right: 12 } })
            Theme.tsChanged()
        }
        function cleanup() {
            for (const key in Theme.ts) delete Theme.ts[key]
            Object.assign(Theme.ts, saved)
            Theme.tsChanged()
        }
        function test_narrow_windows_keep_search() {
            verify(!Theme.headerCanCombine(400, 300))
            verify(Theme.headerCanCombine(940, 300))
        }
        function test_actual_tab_width_matters() {
            verify(Theme.headerCanCombine(650, 100))
            verify(!Theme.headerCanCombine(650, 510))
        }
        function test_large_type_and_controls_get_room() {
            verify(Theme.headerCanCombine(620, 300))
            Theme.ts.fontScale = 2
            Theme.ts.controlScale = 1.5
            Theme.tsChanged()
            verify(!Theme.headerCanCombine(620, 300))
            verify(Theme.headerCanCombine(940, 300))
        }
        function test_stacked_is_always_stacked() {
            Theme.ts.header = "stacked"
            Theme.tsChanged()
            verify(!Theme.headerCanCombine(1800, 300))
        }
    }
}
