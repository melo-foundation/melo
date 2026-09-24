import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A fill lives in window space, so one rainbow crosses every label rather than
// restarting in each, and where an item sits is mapToItem, which is not
// reactive. Reading it a few times a second is right for a still item and
// wrong for a scrolling one: the pattern rides along and then snaps back.
Item {
    width: 300; height: 200
    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: 300; contentHeight: 2000
        Item {
            id: card
            y: 400; width: 200; height: 80
            StyledFill { id: fill; anchors.fill: parent; kind: "opal" }
        }
    }
    StyledFill { id: loose; width: 50; height: 50; kind: "opal" }

    TestCase {
        name: "ScrollFills"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }

        function test_a_fill_finds_the_scroller_it_is_in() {
            compare(fill.scroller, flick, "the nearest Flickable above it")
            compare(loose.scroller, null, "and nothing outside one pays for this")
        }

        function test_the_origin_follows_the_content_without_a_tick() {
            flick.contentY = 0
            wait(30)
            const before = fill.geo0.y
            const tick = Theme.slowTick
            flick.contentY = 250
            // no wait: the point is that it does not need the tick
            compare(Theme.slowTick, tick, "and this did not happen")
            verify(Math.abs(fill.geo0.y - before) > 200,
                   "the origin moved with the content: " + before + " -> " + fill.geo0.y)
        }

        function test_it_keeps_up_across_a_scroll() {
            flick.contentY = 0
            wait(30)
            for (let y = 0; y <= 300; y += 37) {
                flick.contentY = y
                const seen = fill.geo0.y, want = card.mapToItem(null, 0, 0).y
                verify(Math.abs(seen - want) < 0.5,
                       "at contentY " + y + ": origin " + seen + ", item at " + want)
            }
        }
    }
}
