import QtQuick
import QtTest
import "../../src/qml/views"

// A load seeds whole rows that fill the grid the view lays out.
// 396x484 is the page inside the 400x650 default window, where the grid lays
// out two columns.
Item {
    id: rootItem
    width: 396; height: 484

    ListModel { id: m }
    SearchView { id: sv; anchors.fill: parent; model: m; layout: "grid" }

    TestCase {
        name: "SkeletonCount"
        when: windowShown

        function findGrid(item) {
            for (let i = 0; i < item.children.length; i++) {
                const c = item.children[i]
                if (c.gcols !== undefined && c.cellHeight !== undefined) return c
                const g = findGrid(c)
                if (g) return g
            }
            return null
        }

        function test_seed_fills_the_grid_the_view_draws() {
            const grid = findGrid(sv)
            verify(grid, "SearchView grid")
            for (const w of [396, 400, 420, 523, 777, 1024, 1366, 1920]) {
                rootItem.width = w
                for (const h of [300, 484, 800]) {
                    rootItem.height = h
                    const n = sv.placeholderCount()
                    const rows = Math.ceil(sv.height / grid.cellHeight)
                    compare(n % grid.gcols, 0, "partial row: " + n + " tiles in "
                            + grid.gcols + " columns at " + w + "x" + h)
                    compare(n, grid.gcols * Math.min(rows, Math.max(1, Math.floor(60 / grid.gcols))),
                            n + " tiles for " + grid.gcols + "x" + rows + " at " + w + "x" + h)
                }
            }
        }
    }
}
