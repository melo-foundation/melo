import QtQuick
import QtTest
import "../../src/qml"

// Which windows take the theme's shape. A path or an image is the player's:
// it bites into the window, and settings rows have nowhere to go. Corners are
// every window's.
Item {
    TestCase {
        name: "ShapeScope"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() { delete Theme.ts.windowShape; Theme.tsChanged(); wait(20) }
        function set(v) { Theme.ts.windowShape = v; Theme.tsChanged(); wait(20) }

        function isRounded(s, size) {
            return !!s && !!s.corners && s.corners.length === 4
                   && s.corners[0].style === "round" && s.corners[0].size === size
        }

        function test_a_path_is_the_players_alone() {
            const spec = { path: "M0,0 L200,0 L200,120 L100,160 L0,120 Z", box: [200, 160] }
            set(spec)
            compare(Theme.shapeFor(8, 8), spec)
            verify(isRounded(Theme.panelShapeFor(8, 8), 8))
        }

        function test_an_image_is_too() {
            const spec = { image: "file:///nowhere.png", slice: [10, 10, 10, 10] }
            set(spec)
            compare(Theme.shapeFor(8, 8), spec)
            verify(isRounded(Theme.panelShapeFor(8, 8), 8))
        }

        function test_corners_are_every_windows() {
            const spec = { corners: [{ style: "bite", size: 20 }, { style: "round", size: 4 },
                                     { style: "round", size: 4 }, { style: "round", size: 4 }] }
            set(spec)
            compare(Theme.shapeFor(8, 8), spec)
            compare(Theme.panelShapeFor(8, 8), spec)
        }

        function test_a_square_window_has_no_shape_to_keep() {
            compare(Theme.panelShapeFor(0, 0), null)
            verify(isRounded(Theme.panelShapeFor(6, 6), 6))
        }
    }
}
