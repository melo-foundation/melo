import QtQuick
import QtTest
import "../../src/qml"

// The video's and the visualizer's opacity mode: opaque is 1, master is the
// master opacity, custom is its own value, clamped.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_modeopacity.qml
Item {
    TestCase {
        name: "ModeOpacity"

        function test_opaque_is_one() {
            compare(Theme.modeOpacity("opaque", 0.3, 0.4), 1)
        }
        function test_master_is_the_master() {
            fuzzyCompare(Theme.modeOpacity("master", 0.3, 0.4), 0.4, 0.0001)
        }
        function test_custom_is_its_value() {
            fuzzyCompare(Theme.modeOpacity("custom", 0.3, 0.4), 0.3, 0.0001)
            compare(Theme.modeOpacity("custom", 2, 0.4), 1)
            compare(Theme.modeOpacity("custom", -1, 0.4), 0)
            compare(Theme.modeOpacity("custom", undefined, 0.4), 1)
        }
        function test_unknown_or_unset_is_opaque() {
            compare(Theme.modeOpacity(undefined, 0.3, 0.4), 1)
            compare(Theme.modeOpacity("nope", 0.3, 0.4), 1)
        }
        // with no settings: opaque, at full
        function test_defaults() {
            compare(Theme.videoOpacityMode, "opaque")
            compare(Theme.visualizerOpacityMode, "opaque")
            compare(Theme.videoOpacity, 1)
            compare(Theme.visualizerOpacity, 1)
        }
    }
}
