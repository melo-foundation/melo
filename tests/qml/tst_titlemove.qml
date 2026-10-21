import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A press on a window's title bar says which keys were held: a detached window
// arms its reattach from Ctrl there as it does from Ctrl on its body.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_titlemove.qml
Item {
    MeloWindow { id: win; titled: true; heading: "Queue"; width: 400; height: 300; visible: true }
    SignalSpy { id: spy; target: win; signalName: "titleMoveStarting" }

    TestCase {
        name: "titlemove"
        when: windowShown

        function init() { spy.clear() }

        function press(mods) {
            const t = win.titleBarItem
            verify(t.visible && t.height > 0)
            mousePress(t, t.width * 0.35, t.height / 2, Qt.LeftButton, mods)
            mouseRelease(t, t.width * 0.35, t.height / 2, Qt.LeftButton, mods)
            compare(spy.count, 1)
            return spy.signalArguments[0][0]
        }

        function test_ctrl_press_carries_ctrl() {
            verify((press(Qt.ControlModifier) & Qt.ControlModifier) !== 0)
        }

        function test_plain_press_carries_no_ctrl() {
            verify((press(Qt.NoModifier) & Qt.ControlModifier) === 0)
        }
    }
}
