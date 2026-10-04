import QtQuick
import QtTest
import "../../src/qml/components"

// Straight-line glyphs land on whole pixels: every line pixel is full ink, none
// half, and the EQ's three sliders sit the same distance apart.
//
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_glyphhint.qml
Rectangle {
    id: top
    width: 80; height: 30; color: "white"
    property var table: ({
        eq: { fill: false, ink: 24.0, paths: ["M4 21V14", "M4 10V3", "M12 21V12", "M12 8V3",
              "M20 21V16", "M20 12V3", "M1 14H7", "M9 8H15", "M17 16H23"] },
        queue: { fill: false, ink: 18.5, sw: 2.5, paths: ["M4 6H20", "M4 12H20", "M4 18H14"] },
        close: { fill: false, ink: 14.0, paths: ["M18 6L6 18", "M6 6L18 18"] } })
    Glyph { id: eq; x: 4; y: 4; name: "eq"; size: 16; color: "black"; glyphs: top.table }
    Glyph { id: queue; x: 30; y: 4; name: "queue"; size: 16; color: "black"; glyphs: top.table }
    Glyph { id: close; x: 56; y: 4; name: "close"; size: 16; color: "black"; glyphs: top.table }

    TestCase {
        name: "GlyphHint"
        when: windowShown

        function test_curves_are_not_hinted() {
            compare(close.hinted, null)
            verify(eq.hinted !== null)
            verify(queue.hinted !== null)
        }

        // the middle row of a 1 px line crosses no half-covered pixel
        function test_eq_lines_are_whole_pixels() {
            wait(100)
            const img = grabImage(top)
            const cols = []
            for (let x = 4; x < 20; x++) {
                const v = img.pixel(x, 4 + 4).r
                verify(v < 0.2 || v > 0.8, "half-covered pixel at x=" + x + ": " + v)
                if (v < 0.2) cols.push(x)
            }
            compare(cols.length, 3)
            compare(cols[1] - cols[0], cols[2] - cols[1])
        }

        function test_queue_lines_are_the_same_weight() {
            wait(100)
            const img = grabImage(top)
            const runs = []
            let run = 0
            for (let y = 4; y < 20; y++) {
                const v = img.pixel(30 + 6, y).r
                verify(v < 0.2 || v > 0.8, "half-covered pixel at y=" + y + ": " + v)
                if (v < 0.2) run++
                else if (run) { runs.push(run); run = 0 }
            }
            compare(runs.length, 3)
            compare(runs[0], runs[1])
            compare(runs[1], runs[2])
        }
    }
}
