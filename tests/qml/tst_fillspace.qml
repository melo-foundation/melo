import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// What the pattern is anchored to. Three answers and three looks: the window,
// so an item slides across one pattern; the item, so the pattern starts again
// in each and never moves with it; or the scrolled content, so a long list has
// one pattern down all of it and each item keeps its own slice while scrolling.
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
    readonly property var lay: (space) => Theme.layersOf(
        { colour: "#3060ff", source: "opal", params: { speed: 0 }, space: space })

    TestCase {
        name: "FillSpace"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function layerOf() { return findChild(fill, "fillLayer_0") }

        function test_the_format_carries_it() {
            compare(Theme.layersOf("#ff0000")[0].space, "window", "what a fill always did")
            compare(Theme.layersOf({ colour: "#ff0000", space: "item" })[0].space, "item")
            compare(Theme.layersOf({ colour: "#ff0000", space: "nonsense" })[0].space, "window")
            const back = Theme.entryFromLayers(Theme.layersOf({ colour: "#ff0000", space: "scroll" }))
            compare(back.space, "scroll")
            verify(Theme.entryFromLayers(Theme.layersOf("#ff0000")).space === undefined,
                   "the default is not written")
            // and a code carries it
            const code = Theme.entryToCode({ colour: "#ff0000", source: "opal", space: "scroll" })
            verify(code.indexOf("w2") > 0, code)
            compare(Theme.codeToEntry(code).space, "scroll")
        }

        function test_window_space_slides_the_item_across_the_pattern() {
            fill.layers = lay("window")
            flick.contentY = 0
            const a = fill.geo0.y
            flick.contentY = 300
            verify(Math.abs(fill.geo0.y - a) > 200, "the item moved through a fixed pattern")
        }

        // the item's own: it cannot drift, because there is nothing to drift
        // against — every card gets the same little gradient
        function test_item_space_never_moves() {
            fill.layers = lay("item")
            flick.contentY = 0
            wait(30)
            const g = layerOf().geo0
            compare(g.x, 0); compare(g.y, 0)
            compare(g.z, card.width); compare(g.w, card.height)
            flick.contentY = 500
            wait(30)
            compare(layerOf().geo0.y, 0, "and scrolling does nothing to it")
            compare(layerOf().geo1.x, card.width, "the unit is the item, not 800")
        }

        // one pattern down the whole list: the item keeps its slice of it
        function test_scroll_space_travels_with_the_content() {
            fill.layers = lay("scroll")
            flick.contentY = 0
            wait(30)
            const a = layerOf().geo0.y
            compare(a, card.y, "measured in the content, not the viewport")
            flick.contentY = 400
            wait(30)
            compare(layerOf().geo0.y, card.y, "and the content did not move under it")
            compare(layerOf().geo1.x, 800, "still the fixed unit, so a resize rescales nothing")
        }
    }
}
