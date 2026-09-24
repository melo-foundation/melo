import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The popups read their edges from the theme: a menu's rows sit at the `menu`
// inset, a field's text at the `field` one, per side.
Item {
    id: root
    width: 400; height: 300

    DropMenu { id: menu }
    SearchSelect { id: sel; options: [{ value: "a", label: "A" }] }

    TestCase {
        name: "InsetsPopups"
        when: windowShown

        function initTestCase() { Theme.held = true }
        function cleanup() {
            delete Theme.ts.insets
            Theme.tsChanged()
        }
        function cleanupTestCase() { Theme.held = false }

        // NOT openAt(): it reaches for WindowCtl and MELO_FOCUS_DEBUG, which
        // live in melo's binary and not in the test runner. The window's
        // contents exist either way, which is all the edges need.
        function open() {
            menu.actions = [{ label: "One", act: () => {} }]
            const f = findChild(menu, "menuFlick")
            verify(f, "the menu has its flickable")
            return f
        }

        function test_menu_defaults() {
            const f = open()
            compare(f.anchors.leftMargin, 5)
            compare(f.anchors.topMargin, 5)
            compare(f.anchors.rightMargin, 5)
            compare(f.anchors.bottomMargin, 5)
        }

        function test_menu_follows_theme() {
            const f = open()
            Theme.ts.insets = { menu: { left: 2, top: 9 } }
            Theme.tsChanged()
            compare(f.anchors.leftMargin, 2)
            compare(f.anchors.topMargin, 9)
            compare(f.anchors.rightMargin, 5, "a side the theme left out keeps its default")
        }

        function test_field_follows_theme() {
            const label = findChild(sel, "selLabel")
            verify(label, "the select has its label")
            compare(label.x, 8)
            Theme.ts.insets = { input: { left: 3 } }
            Theme.tsChanged()
            compare(label.x, 3)
        }
    }
}
