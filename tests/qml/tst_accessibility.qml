import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"
import "../../src/qml/components/barstyles"

// The window is frameless, so the title bar's buttons are the only window
// controls. Each needs a role, a name, keyboard reach, a key and an assistive
// press that do what a click does, and a focus ring.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_accessibility.qml
Item {
    width: 600; height: 160
    TitleBar { id: title; width: 600 }
    // no PlayerState in the test runner, so this one has no track
    TransportButton { id: next; y: 80; which: "next" }

    SignalSpy { id: searchSpy; target: title; signalName: "searchToggle" }
    SignalSpy { id: settingsSpy; target: title; signalName: "settingsToggle" }

    TestCase {
        name: "accessibility"
        when: windowShown

        function init() { searchSpy.clear(); settingsSpy.clear() }

        // the title bar's own buttons, in row order, keyed by glyph
        function buttons() {
            const out = {}
            function walk(it) {
                for (const c of it.children) {
                    if (c.objectName === "titleButton") out[c.parent.glyph] = c.parent
                    else walk(c)
                }
            }
            walk(title)
            return out
        }
        function ringOf(b) {
            for (const c of b.children)
                if (c.border !== undefined && c.border.width === 2) return c
            return null
        }

        function test_every_window_control_is_named_and_reachable() {
            const b = buttons()
            const want = { search: "Search", settings: "Settings", pin: "Always on top",
                           minimize: "Minimise", maximize: "Maximise", close: "Close" }
            for (const g in want) {
                verify(b[g] !== undefined, g + " button not found")
                compare(b[g].Accessible.role, Accessible.Button, g)
                compare(b[g].Accessible.name, want[g])
                verify(b[g].activeFocusOnTab, g + " cannot be reached by keyboard")
            }
        }

        function test_pin_reports_its_state() {
            const pin = buttons().pin
            verify(pin.Accessible.checkable)
            title.pinned = true
            verify(pin.Accessible.checked)
            title.pinned = false
            verify(!pin.Accessible.checked)
            verify(!buttons().search.Accessible.checkable)
        }

        function test_assistive_press_does_what_the_mouse_does() {
            buttons().search.Accessible.pressAction()
            compare(searchSpy.count, 1)
        }

        function test_space_and_enter_activate_a_focused_control() {
            const s = buttons().search
            s.forceActiveFocus()
            verify(s.activeFocus)
            keyClick(Qt.Key_Space)
            compare(searchSpy.count, 1, "Space")
            keyClick(Qt.Key_Return)
            compare(searchSpy.count, 2, "Return")
            keyClick(Qt.Key_Enter)
            compare(searchSpy.count, 3, "Enter")
        }

        function test_focus_is_visible() {
            const b = buttons()
            const ring = ringOf(b.search)
            verify(ring !== null)
            b.settings.forceActiveFocus()
            verify(!ring.visible, "the ring shows on a control that is not focused")
            b.search.forceActiveFocus()
            verify(ring.visible, "focus moved with nothing on screen to show it")
        }

        function test_tab_moves_between_controls() {
            const b = buttons()
            b.search.forceActiveFocus()
            keyClick(Qt.Key_Tab)
            verify(b.settings.activeFocus, "Tab did not move focus to the next control")
            keyClick(Qt.Key_Space)
            compare(settingsSpy.count, 1)
        }

        // A transport with nothing to play is named but skipped by Tab.
        function test_an_idle_transport_is_named_and_out_of_the_tab_order() {
            compare(next.Accessible.role, Accessible.Button)
            compare(next.Accessible.name, "Next track")
            verify(!next.activeFocusOnTab)
        }
    }
}
