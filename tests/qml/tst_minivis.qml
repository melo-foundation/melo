import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components/barstyles"

// The vis button is built only on a bar whose visAllowed is true
// (WindowCtl.canPlaceWindows); the buttons beside it keep their room.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_minivis.qml
Item {
    width: 300; height: 60

    QtObject {
        id: stubBar
        property bool visAllowed: true
        property bool visActive: false
        property bool eqActive: false
        property bool customising: false
        signal visToggle()
        signal eqToggle()
        signal queueToggle()
    }
    BarGroup { id: group; bar: stubBar; explicitIds: ["eq", "vis"] }

    TestCase {
        name: "MiniVis"
        when: windowShown

        function cleanup() { stubBar.visAllowed = true }
        function button(id) {
            for (const c of group.children)
                if (c.modelData === id) return c
            return null
        }

        function test_vis_drawn_where_windows_can_be_placed() {
            tryCompare(button("vis"), "width", group.size)
            verify(button("vis").visible)
        }

        function test_vis_gone_without_placement() {
            stubBar.visAllowed = false
            tryVerify(() => button("vis") === null)
            compare(button("eq").width, group.size)
            tryCompare(group, "implicitWidth", group.size)
        }
    }
}
