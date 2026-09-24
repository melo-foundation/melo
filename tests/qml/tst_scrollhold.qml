import QtQuick
import QtTest
import "../../src/qml"

// A view holding its header at negative content coordinates moves its origin
// when the header reflows. GridUi.originHold compensates, and must never write
// contentY while the user holds the view: that ends the fling.
Item {
    width: 200; height: 300

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: 200; contentHeight: 4000
        Rectangle { width: 200; height: 4000; color: "grey" }
    }

    TestCase {
        name: "ScrollHold"
        when: windowShown

        // ---- why the rule exists ----
        function test_a_write_to_contentY_ends_a_flick() {
            flick.contentY = 0
            flick.flick(0, -3000)
            wait(50)
            verify(flick.flicking)
            flick.contentY = flick.contentY     // the value it already holds
            wait(50)
            verify(!flick.flicking)
        }
        function test_a_flick_left_alone_runs_on() {
            flick.contentY = 0
            flick.flick(0, -3000)
            wait(50)
            const mid = flick.contentY
            wait(200)
            verify(flick.contentY > mid + 20)
        }

        // ---- the rule ----
        function test_the_users_own_scroll_is_never_overwritten() {
            // at the top, looking at the header, the origin dropping 40: every
            // case that would otherwise write, while the view is being driven
            verify(isNaN(GridUi.originHold(true, true, -400, -440, -40)))
            verify(isNaN(GridUi.originHold(true, false, -400, -440, -40)))
            verify(isNaN(GridUi.originHold(true, false, 300, -440, -40)))
        }
        function test_the_top_stays_the_top() {
            compare(GridUi.originHold(false, true, -400, -440, -40), -440)
            compare(GridUi.originHold(false, true, -400, -300, 100), -300)
        }
        function test_the_header_pays_its_delta_and_the_rows_do_not() {
            // looking at the header: moved by what the header moved
            compare(GridUi.originHold(false, false, -200, -440, -40), -240)
            // ...but never above the new top
            compare(GridUi.originHold(false, false, -420, -440, -40), -440)
            // looking at the rows: row 0 never moved, so neither does the view
            verify(isNaN(GridUi.originHold(false, false, 0, -440, -40)))
            verify(isNaN(GridUi.originHold(false, false, 900, -440, -40)))
        }
    }
}
