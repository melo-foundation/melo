import QtQuick
import QtTest
import "../../src/qml/components"

// The visualizer settings and the playlist flyout close on a press in any other
// melo window and when the window they hang off changes size or place: X11 may
// never make them the focus window, so losing activation never closes them.
Item {
    id: root
    width: 400; height: 300

    // stands in for UiActivity.windowPressed, which qmltestrunner does not have
    QtObject { id: pressSource; signal windowPressed(var window) }
    Window { id: host; width: 300; height: 200; visible: true }

    VisConfigPanel { id: vis; presses: pressSource }
    PlaylistFlyout { id: flyout; presses: pressSource }

    TestCase {
        name: "PopupAway"
        when: windowShown

        function cleanup() { vis.visible = false; flyout.visible = false; wait(350) }

        function show(p) {
            p.transientParent = host
            p.visible = true
            verify(p.visible)
        }

        function test_a_press_in_its_own_window_keeps_it() {
            for (const p of [vis, flyout]) {
                show(p)
                pressSource.windowPressed(p)
                verify(p.visible, p + " closed on its own press")
            }
        }

        function test_a_press_in_another_window_closes_it() {
            for (const p of [vis, flyout]) {
                show(p)
                pressSource.windowPressed(root.Window.window)
                verify(!p.visible, p + " stayed open")
            }
        }

        function test_its_window_resizing_closes_it() {
            for (const p of [vis, flyout]) {
                show(p)
                host.width += 20
                tryCompare(p, "visible", false, 1000)
            }
        }

        function test_its_window_moving_closes_it() {
            for (const p of [vis, flyout]) {
                show(p)
                host.x += 20
                tryCompare(p, "visible", false, 1000)
            }
        }

        function test_left_alone_it_stays() {
            for (const p of [vis, flyout]) {
                show(p)
                wait(300)
                verify(p.visible, p + " closed by itself")
            }
        }

        // the press on the gear closes it before the click: that click must not reopen it
        function test_the_gear_click_that_closed_it_does_not_reopen_it() {
            show(vis)
            pressSource.windowPressed(root.Window.window)
            vis.open(root)
            verify(!vis.visible, "reopened by the click that closed it")
        }
    }
}
