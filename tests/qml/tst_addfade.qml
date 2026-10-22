import QtQuick
import QtTest
import "../../src/qml/components"

// Rows added just before a resize land where the new width puts them; Home's
// rows grow at 760px as the window maximises on launch.
Item {
    id: root
    width: 498; height: 494
    property bool fading: false
    property bool plain: false
    property Transition fadeT: AddFade { enabled: root.fading }
    property Transition fadeGridT: AddFade { enabled: root.fading }
    property Transition plainGridT: Transition {
        enabled: root.fading
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 }
    }
    property Transition plainT: Transition {
        enabled: root.fading
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 }
    }
    ListModel { id: lm }
    ListModel { id: gm }
    ListView {
        id: list
        width: root.width; height: root.height
        model: lm
        spacing: 2
        reuseItems: true
        add: root.plain ? root.plainT : root.fadeT
        delegate: Rectangle {
            required property int index
            width: list.width
            height: width >= 760 ? 64 : 52
        }
    }
    GridView {
        id: grid
        x: root.width
        width: root.width; height: root.height
        model: gm
        cellWidth: width / 4; cellHeight: cellWidth
        add: root.plain ? root.plainGridT : root.fadeGridT
        delegate: Rectangle {
            required property int index
            width: grid.cellWidth; height: grid.cellHeight
        }
    }
    TestCase {
        name: "AddFade"
        when: windowShown
        function init() {
            root.fading = false
            root.width = 498; root.height = 494
            lm.clear(); gm.clear()
            for (let i = 0; i < 8; i++) { lm.append({}); gm.append({}) }
            wait(50)
            root.fading = true
        }
        function cleanup() { root.plain = false }
        function rows(v) {
            const out = []
            for (const k of v.contentItem.children)
                if (k.index !== undefined && k.index >= 0 && k.visible) out.push(k)
            return out.sort((a, b) => a.index - b.index)
        }
        function listMisplaced() {
            let bad = 0, y = 0
            for (const r of rows(list)) {
                if (Math.abs(r.y - y) > 0.5) bad++
                y = r.y + r.height + list.spacing
            }
            return bad
        }
        function gridMisplaced() {
            let bad = 0
            for (const r of rows(grid)) {
                const c = r.index % 4, w = Math.floor(r.index / 4)
                if (Math.abs(r.x - c * grid.cellWidth) > 0.5 || Math.abs(r.y - w * grid.cellHeight) > 0.5) bad++
            }
            return bad
        }
        function grow() {
            for (let i = 0; i < 3; i++) { lm.append({}); gm.append({}) }
            wait(30)
            root.width = 1900; root.height = 1000
            wait(20)
        }
        function test_rowsFollowTheResize() {
            grow()
            compare(listMisplaced(), 0)
            compare(gridMisplaced(), 0)
            wait(250)
            compare(listMisplaced(), 0)
            compare(gridMisplaced(), 0)
        }
        function test_addedRowsStillFade_data() { return [{ tag: "AddFade", plain: false }, { tag: "plain", plain: true }] }
        function test_addedRowsStillFade(d) {
            root.plain = d.plain
            lm.append({})
            list.forceLayout()
            const added = rows(list).find(r => r.index === 8)
            verify(added)
            waitForRendering(list)
            verify(added.opacity < 1)
            tryCompare(added, "opacity", 1, 1000)
        }
        // The cause: a running add transition holds rows at the old width's place.
        // When this fails, Qt moves them itself and AddFade can go.
        function test_plainTransitionStrandsRows() {
            root.plain = true
            grow()
            verify(listMisplaced() > 0, "list rows follow the resize under a plain add transition")
            verify(gridMisplaced() > 0, "grid cells follow the resize under a plain add transition")
        }
    }
}
