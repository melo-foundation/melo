import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The segment pill travels to a newly chosen tab, in either direction, and
// does not travel when the strip is only laid out again.
Item {
    width: 400; height: 100
    property int chosen: 0
    SegmentTrack { id: seg; strip: row; style: "segment" }
    Row {
        id: row
        x: 20; y: 20
        Repeater {
            model: 3
            Item {
                required property int index
                width: 80; height: 24
                readonly property bool active: index === chosen
            }
        }
    }
    TestCase {
        name: "SegmentTrack"
        when: windowShown
        function pill() {
            for (let i = seg.children.length - 1; i >= 0; --i)
                if (seg.children[i].role === "accent") return seg.children[i]
            return null
        }
        function tab(i) { let n = 0; for (const c of row.children) { if (c.active !== undefined) { if (n === i) return c; ++n } } return null }
        function restX(i) { return seg.pad + tab(i).x + seg.inset }
        function init() {
            for (let i = 0; i < 3; ++i) tab(i).width = 80
            chosen = 0; wait(Theme.motionMove + 150)
        }

        function test_travels_right_and_left() {
            const p = pill()
            verify(p !== null)
            compare(p.x, restX(0))
            chosen = 2
            wait(Math.max(16, Theme.motionMove / 3))
            verify(p.x > restX(0) && p.x < restX(2), "slides right: " + p.x)
            tryCompare(p, "x", restX(2), Theme.motionMove + 500)
            chosen = 0
            wait(Math.max(16, Theme.motionMove / 3))
            verify(p.x < restX(2) && p.x > restX(0), "slides left: " + p.x)
            tryCompare(p, "x", restX(0), Theme.motionMove + 500)
        }
        function test_a_relayout_does_not_travel() {
            const p = pill()
            chosen = 1
            tryCompare(p, "x", restX(1), Theme.motionMove + 500)
            wait(Theme.motionMove + 150)
            // the tabs move inside the strip without a new choice
            tab(0).width = 120
            wait(16)
            compare(p.x, restX(1))
        }
    }
}
