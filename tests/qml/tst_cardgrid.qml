import QtQuick
import QtTest
import "../../src/qml/components"

// The Library's playlist and album cards: laid out exactly as a Flow of the
// same cards, but only the rows near the scroller's viewport exist.
Item {
    id: root
    width: 1100; height: 700

    ListModel { id: many }
    ListModel { id: few }

    // the same cards in a Flow: the reference layout
    Flow {
        id: ref
        visible: false
        width: grid.width
        spacing: grid.spacing
        Repeater {
            model: 23
            Rectangle { width: grid.cardWidth; height: grid.cardHeight }
        }
    }

    CardGrid {
        id: grid
        width: 1000
        cardWidth: 196.4; cardHeight: 187.3; spacing: 8
        viewTop: 0; viewHeight: 600
        model: many
        delegate: Rectangle {
            required property int index
            width: grid.cardWidth; height: grid.cardHeight
        }
    }

    TestCase {
        name: "CardGrid"
        when: windowShown

        function initTestCase() {
            for (let i = 0; i < 2000; ++i) many.append({ n: i })
            for (let i = 0; i < 23; ++i) few.append({ n: i })
        }
        function init() {
            grid.model = many; grid.width = 1000; grid.viewTop = 0; grid.viewHeight = 600
            wait(30)
        }
        function view() { for (const c of grid.children) if (c.cellWidth !== undefined) return c; return null }
        // cards built, counted with itemAtIndex: a pooled card stays a visible child, only culled
        function built() {
            let n = 0
            for (let i = 0; i < view().count; ++i) if (view().itemAtIndex(i)) ++n
            return n
        }
        // the card for model row i, as the grid has placed it, in grid coordinates
        function cardAt(i) {
            const c = view().itemAtIndex(i)
            return c ? c.mapToItem(grid, 0, 0) : null
        }

        function test_layout_matches_a_flow_of_the_same_cards() {
            grid.model = few
            grid.viewHeight = 5000   // every card in view, to compare them all
            for (const w of [1000, 999.5, 820, 809.6, 612, 400.8, 403.2, 190]) {
                grid.width = w
                wait(30)
                compare(grid.height, ref.height, "height at width " + w)
                for (let i = 0; i < 23; ++i) {
                    const p = cardAt(i), q = ref.children[i]
                    verify(p !== null, "card " + i + " exists at width " + w)
                    fuzzyCompare(p.x, q.x, 0.01, "x of " + i + " at width " + w)
                    fuzzyCompare(p.y, q.y, 0.01, "y of " + i + " at width " + w)
                }
            }
        }

        function test_only_rows_near_the_viewport_exist() {
            const n = built()
            verify(n < 60, n + " cards built for 2000")
            verify(grid.height > 60000, "the full height is still laid out")
        }

        // every card that crosses the viewport exists, is visible and is where
        // the Flow would put it, wherever the scroller is
        function test_the_viewport_is_always_covered() {
            const cols = grid.cols, rowH = grid.cardHeight + grid.spacing
            for (const top of [0, 150, 2300, 30000.5, grid.height - 600, grid.height - 10, -400]) {
                grid.viewTop = top
                wait(30)
                const r0 = Math.max(0, Math.floor(top / rowH))
                const r1 = Math.min(Math.ceil(2000 / cols) - 1, Math.floor((top + 600) / rowH))
                for (let r = r0; r <= r1; ++r) {
                    for (let c = 0; c < cols; ++c) {
                        const p = cardAt(r * cols + c)
                        verify(p !== null, "row " + r + " col " + c + " at top " + top)
                        fuzzyCompare(p.y, r * rowH, 0.01)
                        fuzzyCompare(p.x, c * (grid.cardWidth + grid.spacing), 0.01)
                    }
                }
                verify(built() < 60)
            }
        }

        // a new model (a filter resets the albums) under a scrolled page
        function test_a_reset_keeps_the_viewport_covered() {
            grid.viewTop = 30000; wait(30)
            grid.model = null; wait(30)
            grid.model = many; wait(30)
            const rowH = grid.cardHeight + grid.spacing
            const r = Math.floor(30000 / rowH) + 1
            const p = cardAt(r * grid.cols)
            verify(p !== null, "row " + r + " after the reset")
            fuzzyCompare(p.y, r * rowH, 0.01)
        }

        // a page never shown has a 0-tall scroller and tiny cards: build next to nothing
        function test_a_hidden_page_builds_almost_nothing() {
            grid.viewHeight = 0; grid.cardWidth = 2; grid.cardHeight = 3; wait(30)
            const n = built()
            grid.cardWidth = 196.4; grid.cardHeight = 187.3
            verify(n <= 10, n + " cards built with no viewport")
        }

        function test_an_empty_model_is_zero_tall() {
            grid.model = null
            wait(30)
            compare(grid.height, 0)
        }
    }
}
