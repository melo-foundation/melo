import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The title bar's pin under each WindowCtl.pinMode.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_pincontrols.qml
Item {
    width: 600; height: 80
    TitleBar { id: title; width: 600 }
    SignalSpy { id: pinSpy; target: title; signalName: "pinToggle" }

    TestCase {
        name: "pincontrols"
        when: windowShown

        function init() { pinSpy.clear(); title.pinned = false }
        function cleanup() { title.pinMode = "kwin" }

        function pin() {
            function walk(it) {
                for (const c of it.children) {
                    if (c.objectName === "titleButton" && c.parent.glyph === "pin") return c.parent
                    const r = walk(c)
                    if (r) return r
                }
                return null
            }
            return walk(title)
        }

        function test_toggle_modes_fire_on_click_and_show_state_data() {
            return [{ tag: "kwin", mode: "kwin" }, { tag: "flag", mode: "flag" }]
        }
        function test_toggle_modes_fire_on_click_and_show_state(d) {
            title.pinMode = d.mode
            const b = pin()
            verify(b.visible)
            verify(b.Accessible.checkable)
            title.pinned = true
            verify(b.active)
            mousePress(b, b.width / 2, b.height / 2)
            compare(pinSpy.count, 0)
            mouseRelease(b, b.width / 2, b.height / 2)
            compare(pinSpy.count, 1)
        }

        function test_menu_mode_fires_on_the_press_and_holds_no_state() {
            title.pinMode = "menu"
            const b = pin()
            verify(b.visible)
            verify(!b.Accessible.checkable)
            title.pinned = true
            verify(!b.active)
            mousePress(b, b.width / 2, b.height / 2)
            compare(pinSpy.count, 1)
            mouseRelease(b, b.width / 2, b.height / 2)
            compare(pinSpy.count, 1)
        }

        function test_menu_opens_under_the_pin() {
            title.pinMode = "menu"
            const b = pin()
            const at = b.mapToItem(null, 0, b.height)
            const p = title.pinPoint()
            compare(p.x, Math.round(at.x))
            compare(p.y, Math.round(at.y))
        }

        function test_none_hides_the_pin() {
            title.pinMode = "none"
            verify(!pin().visible)
        }
    }
}
