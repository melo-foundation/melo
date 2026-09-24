import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

Item {
    width: 240; height: 100
    SelectTab { id: tab; width: 180; height: 30; label: "Example"; active: true }
    TestCase {
        name: "SelectTabInk"
        when: windowShown
        property var original: ({})
        function initTestCase() { failOnWarning(/.*/); Theme.held = true }
        function init() {
            original = Object.assign({}, Theme.p)
            Theme.p.text = "#263246"
            Theme.p.textOnAccent = "#fffaf0"
            Theme.p.textOnSelected = "#173829"
            Theme.p.textOnActive = "#512843"
            Theme.pChanged()
        }
        function cleanup() {
            for (const key in Theme.p) delete Theme.p[key]
            Object.assign(Theme.p, original)
            Theme.pChanged()
        }
        function cleanupTestCase() { Theme.held = false }
        function test_active_ink_data() {
            return [
                { tag: "segment", style: "segment", ink: "textOnAccent" },
                { tag: "filled", style: "filled", ink: "textOnSelected" },
                { tag: "pill", style: "pill", ink: "textOnSelected" },
                { tag: "underline", style: "underline", ink: "text" },
                { tag: "button", style: "button", ink: "textOnActive" }
            ]
        }
        function test_active_ink(data) {
            tab.style = data.style
            wait(10)
            let label = null
            for (const child of tab.children) if (child.text === "Example") label = child
            verify(label !== null)
            compare(label.ink, data.ink)
            compare(label.color, Qt.color(Theme.p[data.ink]))
            // A light accent on a dark page must reverse the ink as well.
            Theme.p.text = "#eaf4ff"
            Theme.p.textOnAccent = "#092518"
            Theme.pChanged()
            wait(10)
            compare(label.color, Qt.color(Theme.p[data.ink]))
        }
    }
}
