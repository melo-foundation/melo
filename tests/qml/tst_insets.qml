import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/views"

// How far in a surface's content sits. The page's four sides and a list row's
// padding come from the theme's `insets`; the defaults below apply when a
// theme names none.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_insets.qml
Item {
    id: root
    width: 500; height: 400

    ListModel {
        id: m
        ListElement { vid: "x"; title: "A title"; channel: "A channel"; duration: 200; thumbnail: "" }
    }
    SearchView { id: sv; anchors.fill: parent; model: m; layout: "list" }

    TestCase {
        name: "Insets"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() { delete Theme.ts.insets; Theme.tsChanged(); wait(20) }
        function set(v) { Theme.ts.insets = v; Theme.tsChanged(); wait(20) }

        // A row may bleed, and the compact layout does not take that away:
        // it sits tighter than the theme asked, never past it.
        function test_a_row_inset_may_be_negative() {
            compare(Theme.rowInset("top", 0), 6)
            compare(Theme.rowInset("top", 3), 3)
            set({ row: { left: -5, top: -2, right: -4, bottom: -2 } })
            compare(Theme.inset("row", "top"), -2)
            compare(Theme.rowInset("top", 0), -2)
            compare(Theme.rowInset("top", 3), -2)   // never past what it asked for
            compare(Theme.rowInset("right", 8), -4)
        }

        function test_the_page_pads_are_the_ten_every_view_left() {
            compare(GridUi.padLeft, 10); compare(GridUi.padTop, 10)
            compare(GridUi.padRight, 10); compare(GridUi.padBottom, 10)
            compare(GridUi.padX, 20); compare(GridUi.padY, 20)
        }
        function test_a_theme_moves_one_side_and_leaves_the_rest() {
            set({ page: { left: 3 } })
            compare(GridUi.padLeft, 3)
            compare(GridUi.padRight, 10)
            compare(GridUi.padX, 13)
        }
        function test_one_number_is_all_four_sides() {
            set({ page: 0 })
            compare(GridUi.padX, 0); compare(GridUi.padY, 0)
        }

        // The heading block takes `pageHeader` from the page's own edge:
        // `page` and `pageHeader` name the same visible edge and must never
        // add. What follows the block clears its bottom.
        function headBlock() {
            for (const c of sv.children) if (c.objectName === "pageHeader") return c
            return null
        }
        function listBox() {
            for (const c of sv.children)
                if (c.contentY !== undefined && c.visible) return c
            return null
        }
        function test_the_page_header_defaults_to_the_pages_ten() {
            const h = headBlock()
            verify(h, "found the heading block")
            for (const side of Theme.insetSides) compare(Theme.insetOf("pageHeader", side), 10)
            compare(h.x, 10); compare(h.y, 10)
            compare(root.width - (h.x + h.width), 10)
        }
        function test_the_page_and_the_header_insets_do_not_add() {
            const h = headBlock()
            set({ page: { right: 40 }, pageHeader: { right: 40 } })
            compare(root.width - (h.x + h.width), 40, "one visible edge, one inset")
            set({ page: { left: 40 }, pageHeader: { left: 40 } })
            compare(h.x, 40)
        }
        function test_the_page_moves_the_list_and_the_header_moves_itself() {
            const h = headBlock(), l = listBox()
            verify(l, "found the list")
            const x0 = h.x, lw0 = l.width
            set({ pageHeader: { left: 30 } })
            compare(h.x, 30, "the header follows its own inset")
            compare(l.width, lw0, "and leaves the content column alone")
            set({ page: { left: 30 } })
            compare(h.x, x0, "the page leaves the header alone")
            compare(l.width, lw0 - 20)
        }
        function test_the_page_header_bottom_pushes_what_follows() {
            const l = listBox()
            verify(l, "found the list")
            const y0 = l.y
            set({ pageHeader: { bottom: 19 } })
            compare(l.y, y0 + 9)
        }

        // the delegate's Row carries the row inset on all four sides
        function rowBox() {
            for (const d of sv.children) {
                if (d.contentItem === undefined) continue
                for (const r of d.contentItem.children)
                    for (const c of r.children)
                        if (c.spacing !== undefined) return c
            }
            return null
        }
        function test_the_list_row_pads_are_what_it_always_had() {
            wait(50)
            const b = rowBox()
            verify(b, "found the row")
            compare(b.anchors.leftMargin, 6); compare(b.anchors.topMargin, 6)
            compare(b.anchors.rightMargin, 16); compare(b.anchors.bottomMargin, 6)
            set({ row: { left: 20 } })
            compare(rowBox().anchors.leftMargin, 20)
        }
        // compact sits tighter by a fixed trim, and never past what the
        // theme asked for — which is the edge, unless the theme asked to
        // cross it (see test_a_row_inset_may_be_negative)
        function test_the_compact_row_trims_the_inset_and_stops_at_zero() {
            sv.layout = "compact"
            wait(50)
            const b = rowBox()
            verify(b, "found the compact row")
            compare(b.anchors.leftMargin, 8); compare(b.anchors.topMargin, 3)
            compare(b.anchors.rightMargin, 8); compare(b.anchors.bottomMargin, 3)
            set({ row: 0 })
            const c = rowBox()
            compare(c.anchors.leftMargin, 2)
            compare(c.anchors.topMargin, 0); compare(c.anchors.rightMargin, 0)
            sv.layout = "list"
        }
    }
}
