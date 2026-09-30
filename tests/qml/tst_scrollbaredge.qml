import QtQuick
import QtTest
import QtQuick.Controls as QQC
import "../../src/qml"
import "../../src/qml/views"
import "../../src/qml/components"

// A page's scrollbar sits at the page's right edge, not the capped column's,
// and the scrollbar inset's right side is measured from that edge.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_scrollbaredge.qml
Item {
    id: rootItem
    width: 1600; height: 500

    ListModel { id: m }
    SearchView { id: sv; anchors.fill: parent; model: m; layout: "list" }

    Item {
        id: panel
        x: 200; y: 40; width: 300; height: 200
        clip: true
        Column {
            anchors.fill: parent
            Item { width: parent.width; height: 30 }
            ListView {
                id: plist
                QQC.ScrollBar.vertical: pbar
                width: parent.width; height: parent.height - y
                clip: true
                model: 100
                delegate: Item { width: plist.width; height: 20 }
            }
        }
        MScrollBar { id: pbar; scroller: plist }
    }

    ListView {
        id: flist
        QQC.ScrollBar.vertical: fbar
        x: 600; y: 40; width: 300; height: 200
        model: 3
        delegate: Item { width: flist.width; height: 20 }
    }
    MScrollBar { id: fbar; scroller: flist }

    TestCase {
        name: "ScrollbarEdge"
        when: windowShown

        function initTestCase() {
            for (let i = 0; i < 80; ++i)
                m.append({ vid: "v" + i, title: "Track " + i, channel: "c", duration: 100, thumbnail: "" })
            wait(100)
        }
        function cleanup() {
            delete Theme.ts.insets
            Theme.tsChanged(); wait(20)
        }
        function setRight(v) {
            Theme.ts.insets = { scrollbar: { right: v } }
            Theme.tsChanged(); wait(20)
        }
        function listOf(view) {
            for (const c of view.children)
                if (c.contentY !== undefined && c.visible && c.model === m) return c
            return null
        }
        function barOf(view) {
            for (const c of view.children)
                if (c.scroller !== undefined && c.visible) return c
            return null
        }

        function test_the_bar_sits_at_the_page_edge_not_the_column() {
            const list = listOf(sv), bar = barOf(sv)
            verify(list && bar)
            verify(list.width < sv.width - 200, "the column is capped: " + list.width)
            compare(bar.parent, sv, "a sibling of the list, outside its clip")
            compare(bar.scroller, list)
            compare(bar.y, list.y)
            compare(bar.height, list.height)
            for (const r of [2, 0, -4, 6]) {
                setRight(r)
                const thumb = bar.contentItem.mapToItem(sv, 0, 0)
                compare(Math.round(thumb.x + bar.contentItem.width), sv.width - r,
                        "the thumb's right edge is " + r + " from the page's")
            }
        }

        function test_the_bar_still_drives_the_list() {
            const list = listOf(sv), bar = barOf(sv)
            list.contentY = list.originY
            wait(20)
            compare(bar.position, 0)
            verify(bar.size > 0 && bar.size < 1)
            list.contentY = list.originY + 400
            wait(20)
            verify(bar.position > 0, "the list moves the bar")
            bar.position = 0
            wait(20)
            fuzzyCompare(list.contentY, list.originY, 1, "the bar moves the list")
            // a drag on the thumb scrolls
            const c = bar.contentItem.mapToItem(rootItem, bar.contentItem.width / 2, bar.contentItem.height / 2)
            mouseDrag(rootItem, c.x, c.y, 0, 150)
            wait(20)
            verify(list.contentY > list.originY + 50, "dragging the thumb scrolls: " + list.contentY)
            // the wheel over the bar goes to the list (WheelScroll reads
            // Settings, which the runner lacks, so the handler is checked)
            const ws = bar.children.filter((c) => c.target !== undefined && c.chain !== undefined)
            compare(ws.length, 1)
            compare(ws[0].target, list)
            compare(ws[0].width, bar.width)
            compare(ws[0].height, bar.height)
        }

        function test_a_panel_bar_sits_at_the_panel_edge() {
            compare(pbar.y, plist.y)
            setRight(0)
            const t = pbar.contentItem.mapToItem(panel, 0, 0)
            compare(Math.round(t.x + pbar.contentItem.width), panel.width)
            pbar.position = 0.5
            wait(20)
            verify(plist.contentY > 0)
        }

        function test_a_hidden_list_hides_its_bar() {
            sv.layout = "grid"
            wait(50)
            const bars = sv.children.filter((c) => c.scroller !== undefined)
            compare(bars.filter((b) => b.visible).length, 1, "only the grid's bar")
            sv.layout = "list"
            wait(50)
        }

        function test_the_bar_hides_while_the_content_fits() {
            flist.model = 3; wait(20)
            verify(!fbar.visible, "3 rows fit: size " + fbar.size)
            flist.model = 100; wait(20)
            verify(fbar.visible, "100 rows overflow: size " + fbar.size)
            fbar.policy = QQC.ScrollBar.AlwaysOn; flist.model = 3; wait(20)
            verify(fbar.visible, "AlwaysOn stays")
            fbar.policy = QQC.ScrollBar.AsNeeded
        }
    }
}
