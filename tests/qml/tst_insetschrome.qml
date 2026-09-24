import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// An inset is what a theme says about an edge. The chrome reads its
// structure's inset rather than a literal, so a theme with a bevel can hold
// its content off the edge; a theme that names none gets the defaults.
Item {
    width: 600; height: 200
    AppTabBar { id: tabs; width: 600 }
    TitleBar { id: title; width: 600; y: 40 }

    TestCase {
        name: "InsetsChrome"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() { delete Theme.ts.insets; Theme.tsChanged(); wait(20) }
        function set(v) { Theme.ts.insets = v; Theme.tsChanged(); wait(20) }

        function rowOf(item) {   // the Row of tabs / of window buttons
            for (const c of item.children)
                if (c.spacing !== undefined && c.strip === undefined) return c
            return null
        }
        function labelOf(item) {
            for (const c of item.children) if (c.ink !== undefined) return c
            return null
        }

        function test_the_defaults_are_todays_numbers() {
            compare(Theme.inset("tabs", "left"), 8)
            compare(rowOf(tabs).x, 8)
            compare(tabs.implicitWidth, rowOf(tabs).width + 16)
            compare(labelOf(title).x, 10)
            compare(title.width - (rowOf(title).x + rowOf(title).width), 4)
        }

        // A band of the window runs to the frame and what sits on it comes in
        // by the cut: the title bar is one of those bands, so its own inset
        // and the window's cut both move the label.
        function test_the_cut_moves_what_sits_on_the_title() {
            const at = labelOf(title).x
            const right = title.width - (rowOf(title).x + rowOf(title).width)
            title.cutLeft = 20
            title.cutRight = 12
            wait(20)
            compare(labelOf(title).x, at + 20)
            compare(title.width - (rowOf(title).x + rowOf(title).width), right + 12)
            title.cutLeft = 0
            title.cutRight = 0
            wait(20)
            compare(labelOf(title).x, at)
        }

        // A negative inset is a bleed: what sits on a surface may hang over
        // its edge, and nothing on the way in rounds that back up to zero.
        function test_an_inset_may_be_negative() {
            set({ tabs: { left: -4 }, title: { left: -3, right: -5 } })
            compare(Theme.inset("tabs", "left"), -4)
            compare(rowOf(tabs).x, -4)
            compare(labelOf(title).x, -3)
            compare(title.width - (rowOf(title).x + rowOf(title).width), -5)
        }

        function test_a_theme_moves_the_tabs_and_the_title() {
            set({ tabs: { left: 3 }, title: { left: 2, right: 9 } })
            compare(rowOf(tabs).x, 3)
            compare(tabs.implicitWidth, rowOf(tabs).width + 3 + 8)
            compare(labelOf(title).x, 2)
            compare(title.width - (rowOf(title).x + rowOf(title).width), 9)
        }
    }
}
