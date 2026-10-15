import QtQuick
import QtTest
import "../../src/qml/components/layoutstate.js" as LayoutState

// The window layout reopens as it was left: mini or full, maximised, the popup
// under the bar, and every window that was open.
TestCase {
    name: "LayoutRestore"

    function getter(ui) { return (k, f) => ui.hasOwnProperty(k) ? ui[k] : f }

    function test_nothing_saved_opens_full_size() {
        const p = LayoutState.plan(getter({}), true)
        compare(p.mini, false)
        compare(p.maximized, false)
        compare(p.popup, "")
        compare(p.miniAt, null)
        compare(p.windows.length, 0)
    }

    function test_mini_with_both_windows_open() {
        const p = LayoutState.plan(getter({
            "layout": { mini: true, popup: "", miniX: 640, miniY: 900 },
            "window.queue": { x: 100, y: 120, w: 420, h: 400, detached: true, open: true },
            "window.vis": { x: 600, y: 120, w: 420, h: 400, detached: true, open: true },
            "window.video": { detached: true, open: false }
        }), true)
        compare(p.mini, true)
        compare(p.miniAt, { x: 640, y: 900 })
        compare(p.windows, ["queue", "vis"])
    }

    function test_an_attached_kind_is_not_a_window() {
        // open but put back under the bar: the popup shows it instead
        const ui = { "window.vis": { open: true, detached: false } }
        compare(LayoutState.plan(getter(ui), true).windows.length, 0)
        // without window placement every kind is a window
        compare(LayoutState.plan(getter(ui), false).windows, ["vis"])
    }

    function test_maximised_only_at_full_size() {
        compare(LayoutState.plan(getter({ "layout": { maximized: true } }), true).maximized, true)
        compare(LayoutState.plan(getter({ "layout": { maximized: true, mini: true } }), true).maximized, false)
    }

    function test_popup_only_in_the_mini_player_with_placement() {
        compare(LayoutState.plan(getter({ "layout": { mini: true, popup: "vis" } }), true).popup, "vis")
        compare(LayoutState.plan(getter({ "layout": { mini: true, popup: "queue" } }), true).popup, "queue")
        compare(LayoutState.plan(getter({ "layout": { mini: false, popup: "queue" } }), true).popup, "")
        compare(LayoutState.plan(getter({ "layout": { mini: true, popup: "queue" } }), false).popup, "")
        compare(LayoutState.plan(getter({ "layout": { mini: true, popup: "bogus" } }), true).popup, "")
    }

    function test_a_malformed_save_opens_full_size() {
        const p = LayoutState.plan(getter({ "layout": "mini", "window.queue": 3 }), true)
        compare(p.mini, false)
        compare(p.windows.length, 0)
        compare(LayoutState.plan(getter({ "layout": { mini: true, miniX: "1" } }), true).miniAt, null)
    }

    function test_popup_shows() {
        compare(LayoutState.popupOf(true, false, false), "vis")
        compare(LayoutState.popupOf(true, true, false), "vis")
        compare(LayoutState.popupOf(false, true, false), "queue")
        compare(LayoutState.popupOf(false, true, true), "")      // the queue is in its window
        compare(LayoutState.popupOf(false, false, false), "")
    }

    function st(o) {
        return Object.assign({ recording: true, toggling: false, miniPlayer: false, popup: "", visibility: "windowed" }, o)
    }

    function test_nothing_saved_while_quitting_or_toggling() {
        compare(LayoutState.record(st({ recording: false })), null)
        compare(LayoutState.record(st({ toggling: true })), null)
    }

    function test_hidden_main_keeps_maximised() {
        // closing melo hides main: that must not read as "not maximised"
        compare(LayoutState.record(st({ visibility: "other" })), { mini: false })
        compare(LayoutState.record(st({ visibility: "maximized" })), { mini: false, maximized: true })
        compare(LayoutState.record(st({ visibility: "windowed" })), { mini: false, maximized: false })
    }

    function test_mini_saves_the_popup_not_maximised() {
        compare(LayoutState.record(st({ miniPlayer: true, popup: "vis", visibility: "windowed" })), { mini: true, popup: "vis" })
        compare(LayoutState.record(st({ miniPlayer: true, popup: "" })), { mini: true, popup: "" })
    }

    // what record() saves, plan() reopens
    function test_round_trip() {
        const f = LayoutState.record(st({ miniPlayer: true, popup: "queue" }))
        const p = LayoutState.plan(getter({ "layout": f }), true)
        compare(p.mini, true)
        compare(p.popup, "queue")
    }

    readonly property var twoScreens: [{ x: 0, y: 0, width: 1920, height: 1080 }, { x: 1920, y: 0, width: 2560, height: 1440 }]

    function test_a_place_stays_on_its_screen() {
        compare(LayoutState.onScreen(2200, 300, 1000, 700, twoScreens), { x: 2200, y: 300 })
        // past the right screen's edge: pulled back onto it, not onto the left one
        compare(LayoutState.onScreen(3900, 300, 1000, 700, twoScreens), { x: 3480, y: 300 })
    }

    function test_a_place_on_no_screen_is_dropped() {
        compare(LayoutState.onScreen(9000, 300, 1000, 700, twoScreens), null)
    }

    function test_x11_places_before_mapping_then_maximises() {
        const at = { x: 2200, y: 300 }
        compare(LayoutState.mainStart(true, at, true, false), { preplace: at, maximizeNow: true, maximizeByKwin: false })
        compare(LayoutState.mainStart(true, at, true, true), { preplace: at, maximizeNow: true, maximizeByKwin: false })
        compare(LayoutState.mainStart(false, at, true, false), { preplace: at, maximizeNow: false, maximizeByKwin: false })
    }

    function test_kwin_wayland_moves_then_maximises() {
        const at = { x: 2200, y: 300 }
        compare(LayoutState.mainStart(true, at, false, true), { preplace: null, maximizeNow: false, maximizeByKwin: true })
        // nothing saved: it maps maximised where KWin puts it
        compare(LayoutState.mainStart(true, null, false, true), { preplace: null, maximizeNow: true, maximizeByKwin: false })
    }

    function test_other_wayland_desktops_map_maximised() {
        compare(LayoutState.mainStart(true, { x: 2200, y: 300 }, false, false), { preplace: null, maximizeNow: true, maximizeByKwin: false })
    }
}
