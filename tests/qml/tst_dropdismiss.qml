import QtQuick
import QtTest
import "../../src/qml/components"

// A dropdown closes on a click anywhere in its window, its own field included.
// A press inside melo's own window often does not take activation off the
// popup, so closing on lost activation alone would leave a menu open on any
// screen without a scrim of its own; the menus close themselves.
Item {
    id: root
    width: 400; height: 300

    DropMenu { id: dm }
    Rectangle { id: head; x: 10; y: 10; width: 120; height: 24; color: "gray" }
    // a field wider than anything in its list, as the rows of a settings
    // page or the wizard are
    Rectangle { id: wideHead; x: 10; y: 40; width: 260; height: 24; color: "gray" }
    // the language and region fields: a popup of its own, with a filter field
    SearchSelect { id: sel; x: 10; y: 80; width: 150; height: 24
                   options: [{ value: "a", label: "A" }, { value: "b", label: "B" }] }

    TestCase {
        name: "DropDismiss"
        when: windowShown

        // a menu left open by a failed test covers the window with its scrim
        // and swallows the next test's clicks
        function cleanup() { dm.close() }

        function openMenu() {
            dm.openAt(root.Window.window, head.x, head.y + head.height,
                      [{ label: "One", act: () => {} }, { label: "Two", act: () => {} }], head)
            verify(dm.visible, "menu did not open")
        }

        function test_a_click_elsewhere_in_the_window_closes_it() {
            openMenu()
            mouseClick(root, 350, 250)
            tryCompare(dm, "visible", false, 1000)
        }

        function test_a_click_on_its_own_field_closes_it() {
            openMenu()
            mouseClick(root, head.x + 20, head.y + 10)
            tryCompare(dm, "visible", false, 1000)
        }

        // the field ignores a click within 300ms of the popup closing, so a
        // test that reopens straight after another closed it waits that out
        function openSelect() {
            wait(350)
            mouseClick(sel)
            tryCompare(sel, "open", true, 1000)
        }

        function test_a_search_select_closes_on_a_click_elsewhere() {
            openSelect()
            mouseClick(root, 350, 250)
            tryCompare(sel, "open", false, 1000)
        }

        function test_a_search_select_closes_on_its_own_field() {
            openSelect()
            mouseClick(sel)
            tryCompare(sel, "open", false, 1000)
        }

        // A dropdown is at least as wide as its field: sized to its longest
        // label alone, it would hang off the left edge under a field that
        // fills its row.
        function test_a_menu_is_as_wide_as_the_field_it_drops_from() {
            dm.openAt(root.Window.window, wideHead.x, wideHead.y + wideHead.height,
                      [{ label: "Off", act: () => {} }, { label: "On", act: () => {} }], wideHead)
            verify(dm.width >= wideHead.width, "menu " + dm.width + " narrower than field " + wideHead.width)
            dm.close()
        }

        function test_a_long_label_still_widens_the_menu_past_a_narrow_field() {
            dm.openAt(root.Window.window, head.x, head.y + head.height,
                      [{ label: "A label a good deal longer than its field", act: () => {} }], head)
            verify(dm.width > head.width, "menu did not grow for its label")
            dm.close()
        }
    }
}
