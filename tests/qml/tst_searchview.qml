import QtQuick
import QtTest
import "../../src/qml/views"

// Hover-marquee test against the REAL SearchView delegate structure.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml
Item {
    id: rootItem
    width: 500; height: 300

    ListModel {
        id: m
        ListElement {
            vid: "x"
            title: "An extremely long track title that will surely overflow the available width of the row"
            channel: "A channel name that is also very long and will overflow its narrow row for certain, yes truly"
            duration: 200
            thumbnail: ""
        }
    }

    SearchView { id: sv; anchors.fill: parent; model: m; layout: "list" }

    TestCase {
        name: "SearchViewMarquee"
        when: windowShown

        function findScrollTexts(item, out) {
            for (let i = 0; i < item.children.length; i++) {
                const c = item.children[i]
                if (c.scrollX !== undefined && c.overflow !== undefined) out.push(c)
                findScrollTexts(c, out)
            }
        }

        function test_row_marquee() {
            wait(200)
            const sts = []
            findScrollTexts(sv, sts)
            verify(sts.length >= 2, "found ScrollTexts in delegate: " + sts.length)
            for (let i = 0; i < sts.length; i++) {
                const st = sts[i]
                if (!st.visible) continue
                const c = st.mapToItem(rootItem, st.width / 2, st.height / 2)
                mouseMove(rootItem, c.x, c.y)
                wait(60)
                verify(st.overflow > 1, "st[" + i + "] overflow=" + st.overflow)
                verify(st.scrolling, "st[" + i + "] scrolling (extHover=" + st.extHover
                       + " hoverSource=" + st.hoverSource + ")")
                wait(st.ms * 0.2)
                verify(st.scrollX < -1, "st[" + i + "] moved: " + st.scrollX)
            }
        }
    }
}
