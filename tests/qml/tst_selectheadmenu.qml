import QtQuick
import QtQuick.Window
import QtTest
import "../../src/qml"
import "../../src/qml/components"

Item {
    width: 320; height: 120
    Window {
        id: menuWindow
        width: 100; height: 50
        visible: false
        property Item owner: null
    }
    SelectHead { id: first; label: "First"; menu: menuWindow; width: 120; height: 30 }
    SelectHead { id: second; label: "Second"; menu: menuWindow; y: 40; width: 120; height: 30 }

    TestCase {
        name: "SelectHeadMenu"
        when: windowShown
        function cleanup() { menuWindow.visible = false; menuWindow.owner = null }
        function test_window_is_not_discarded() {
            compare(first.menu, menuWindow)
            compare(second.menu, menuWindow)
            verify(!first.open)
        }
        function test_shared_window_activates_only_its_owner() {
            menuWindow.owner = first
            menuWindow.visible = true
            tryCompare(first, "open", true)
            verify(!second.open)
            compare(findChild(first, "selFace").role, "buttonActive")
            menuWindow.owner = second
            tryCompare(second, "open", true)
            verify(!first.open)
            menuWindow.visible = false
            tryCompare(second, "open", false)
        }
    }
}
