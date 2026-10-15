import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The main window's insets while maximised: `insets.maximized` per structure,
// the normal inset where it names none, and other windows never take them.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_insetsmaximized.qml
Item {
    id: root
    width: 400; height: 300

    Flickable { id: flick; width: 200; height: 100; contentHeight: 1000 }
    MScrollBar { id: mainBar; scroller: flick; mainWindow: true }
    MScrollBar { id: otherBar; scroller: flick }

    TestCase {
        name: "InsetsMaximized"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() { Theme.maximized = false; delete Theme.ts.insets; Theme.tsChanged(); wait(20) }
        function set(v) { Theme.ts.insets = v; Theme.tsChanged(); wait(20) }

        function test_an_unset_maximised_value_is_the_normal_one() {
            set({ page: { left: 3 }, title: { top: 2 } })
            Theme.maximized = true
            compare(Theme.inset("page", "left"), 3)
            compare(GridUi.padLeft, 3)
            compare(Theme.mainInset("title", "top"), 2)
            compare(Theme.mainInset("title", "left"), 10)
            compare(Theme.insetMaxOf("page", "left"), 3)
            verify(!Theme.insetMaxSet("page", "left"))
        }

        function test_a_maximised_value_applies_only_while_maximised() {
            set({ page: { left: 3 }, maximized: { page: { left: 0 }, header: 0, title: { top: 4 } } })
            compare(GridUi.padLeft, 3)
            compare(Theme.inset("header", "left"), 10)
            compare(Theme.mainInset("title", "top"), 0)
            Theme.maximized = true
            compare(GridUi.padLeft, 0)
            compare(Theme.inset("page", "right"), 10, "the sides it leaves out stay")
            compare(Theme.inset("header", "left"), 0)
            compare(Theme.mainInset("title", "top"), 4)
            compare(Theme.mainTitleBarH, Theme.titleBarH + 4)
            verify(Theme.insetMaxSet("title", "top"))
            Theme.maximized = false
            compare(GridUi.padLeft, 3)
            compare(Theme.mainTitleBarH, Theme.titleBarH)
        }

        // title, scrollbar and panel are drawn by other windows too: plain
        // inset() keeps their normal values
        function test_other_windows_keep_their_insets() {
            set({ maximized: { title: { left: 1 }, scrollbar: { right: 0 }, panel: 0 } })
            Theme.maximized = true
            compare(Theme.inset("title", "left"), 10)
            compare(Theme.inset("scrollbar", "right"), 2)
            compare(Theme.inset("panel", "left"), 12)
            compare(Theme.mainInset("panel", "left"), 0)
            compare(mainBar.rightPadding, 0)
            compare(otherBar.rightPadding, 2)
        }

        // the settings window's tabs and the mini player fall back to the
        // normal tabs and player, never the maximised ones
        function test_fallbacks_take_the_normal_values() {
            set({ maximized: { tabs: { left: 0 }, player: { top: 0 } } })
            Theme.maximized = true
            compare(Theme.inset("tabs", "left"), 0)
            compare(Theme.inset("pageTabs", "left"), 8)
            compare(Theme.inset("player", "top"), 0)
            compare(Theme.inset("miniPlayer", "top"), 6)
        }
    }
}
