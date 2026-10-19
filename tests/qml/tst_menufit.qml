import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A menu is as wide as its longest label needs, theme insets included: no label elides.
Item {
    id: root
    width: 600; height: 400

    DropMenu { id: drop }
    ContextMenu { id: cm }

    readonly property var labels: [
        { label: "Rename…", act: () => {} },
        { label: "Select places", act: () => {} },
        { label: "Assign by picking…", act: () => {} },
        { label: "Delete", act: () => {}, rule: true },
    ]

    TestCase {
        name: "MenuFit"
        when: windowShown

        function initTestCase() { Theme.held = true }
        function cleanup() {
            delete Theme.ts.insets
            Theme.tsChanged()
            cm.close()
        }
        function cleanupTestCase() { Theme.held = false }

        function labelsIn(item) {
            const out = []
            const walk = (o) => {
                for (let i = 0; i < o.children.length; i++) {
                    const c = o.children[i]
                    if (c.hasOwnProperty("truncated") && c.text && c.visible) out.push(c)
                    walk(c)
                }
            }
            walk(item)
            return out
        }

        function noneCut(item, what) {
            const ts = labelsIn(item)
            verify(ts.length >= root.labels.length, what + ": found its labels")
            for (const t of ts) verify(!t.truncated, what + ": '" + t.text + "' is cut off")
        }

        function test_drop_with_wide_insets() {
            Theme.ts.insets = { menu: { left: 22, right: 22 } }
            Theme.tsChanged()
            drop.actions = root.labels
            drop.width = drop.fitWidth(root.labels)
            // a hidden window does not size its content; a shown one fills it to its width
            drop.contentItem.width = drop.width
            wait(50)
            noneCut(drop.contentItem, "drop menu")
        }

        function test_context_with_wide_insets() {
            Theme.ts.insets = { menu: { left: 22, right: 22 } }
            Theme.tsChanged()
            cm.open(10, 10, root.labels)
            wait(50)
            const col = findChild(cm, "menuColumn")
            verify(col, "the context menu has its column")
            noneCut(col, "context menu")
        }
    }
}
