import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The offscreen runner uses the software scene graph, which cannot draw
// ShaderEffect. Run the real shaders locally with:
// QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
//     qmltestrunner-qt6 -input tests/qml/tst_borderblur.qml
//
// A frame's outer edge (window rim) and inner edge soften as the theme asks;
// the whole frame's coverage fades, and the bands keep their hard lines.
Rectangle {
    id: scene
    width: 120; height: 120
    color: "#000000"

    WindowBorder {
        id: wb
        anchors.fill: parent
        borderLeft: 20; borderTop: 20; borderRight: 20; borderBottom: 20
        bands: [{ width: 20, colour: "#ffffff" }]
        softOuter: 0
        softInner: 0
    }

    TestCase {
        name: "BorderBlur"
        when: windowShown

        function initTestCase() {
            failOnWarning(/Failed to (compile shader|build graphics pipeline)/)
            Theme.held = true
        }
        function init() {
            if (scene.GraphicsInfo.api === GraphicsInfo.Software)
                skip("ShaderEffect needs an RHI backend; use the command above")
        }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() {
            wb.softOuter = 0; wb.softInner = 0; wb.softBands = 0; wb.softCurve = "smooth"
            wb.bands = [{ width: 20, colour: "#ffffff" }]
        }

        // the frame across its own left side, outer edge inward, as greys
        function profile(outer, inner) {
            wb.softOuter = outer
            wb.softInner = inner
            wait(50)
            const img = grabImage(scene)
            const k = Math.round(img.width / scene.width)   // device pixels
            const y = Math.round(img.height / 2)
            const out = []
            for (let i = 0; i < 20; ++i) out.push(img.red(i * k, y))
            return out
        }
        function rises(p, from, to) {
            for (let i = from + 1; i <= to; ++i) if (p[i] < p[i - 1] - 2) return false
            return true
        }

        function test_a_frame_that_asks_for_no_blur_has_none() {
            const p = profile(0, 0)
            verify(p[0] > 200)       // white at the rim
            verify(p[19] > 200)      // ...and to the last pixel of the band
        }

        function test_the_outer_edge_fades_in_from_the_rim() {
            const hard = profile(0, 0)
            const soft = profile(12, 0)
            verify(soft[0] < 60)          // the rim is nearly the window's own
            verify(soft[0] < hard[0] - 100)
            verify(rises(soft, 0, 11))    // ...and climbs to the frame
            verify(soft[15] > 200)        // past the softness it is the frame
        }

        function test_the_inner_edge_fades_out_into_what_it_frames() {
            const soft = profile(0, 12)
            verify(soft[0] > 200)         // the rim is the frame
            verify(soft[19] < 60)         // ...and it is gone by the inner edge
            verify(soft[8] > soft[14])
            verify(soft[14] > soft[19])
        }

        function test_the_curve_changes_the_shape_of_the_fade() {
            wb.softCurve = "linear"
            const lin = profile(16, 0)
            wb.softCurve = "glow"
            const glow = profile(16, 0)
            wb.softCurve = "smooth"
            // halfway along the fade a glow is still near the window, a
            // straight line is halfway to the frame
            verify(lin[8] > 90 && lin[8] < 170)
            verify(glow[8] < lin[8] - 30)
            verify(glow[15] > 180)     // ...and both arrive at the frame
            verify(lin[15] > 180)
        }

        function test_a_band_edge_blurs_into_its_neighbour() {
            wb.bands = [{ width: 10, colour: "#ffffff" }, { width: 10, colour: "#606060" }]
            const hard = profile(0, 0)
            wb.softBands = 8
            const soft = profile(0, 0)
            wb.softBands = 0
            wb.bands = [{ width: 20, colour: "#ffffff" }]
            // the white runs into the grey instead of stopping at it
            let steps = 0
            for (let i = 6; i < 14; ++i) if (soft[i] > 110 && soft[i] < 245) ++steps
            verify(steps >= 4)
            compare(hard[4] > 200, true)
            // ...and what one band loses the other gains: no seam darker than
            // either of them
            for (let i = 2; i < 18; ++i) verify(soft[i] > 80)
        }

        function test_both_edges_at_once_leave_the_middle() {
            const soft = profile(8, 8)
            verify(soft[0] < 60)
            verify(soft[19] < 60)
            verify(soft[10] > 180)        // the frame is itself between them
        }
    }
}
