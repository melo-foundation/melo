import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// Run with a real shader backend, as tst_styledfills.qml describes. These
// assertions distinguish a real shape field from a bounding-box decoration.
Rectangle {
    id: scene
    width: 360; height: 160
    color: "#101820"
    property bool hole: true
    property real holeX: 80
    property Item usedMask: frameMask

    Item {
        width: 0; height: 0; clip: true
        Item {
            id: frameMask
            width: 160; height: 120; layer.enabled: true
            Rectangle { x: 16; y: 12; width: scene.holeX - 28; height: 96; color: "white" }
            Rectangle { x: scene.holeX + 12; y: 12; width: 136 - scene.holeX; height: 96; color: "white" }
            Rectangle { x: scene.holeX - 12; y: 12; width: 24; height: 36; color: "white" }
            Rectangle { x: scene.holeX - 12; y: 72; width: 24; height: 36; color: "white" }
            Rectangle { x: scene.holeX - 12; y: 48; width: 24; height: 24; color: "white"; visible: !scene.hole }
        }
        Rectangle {
            id: roundedMask
            width: 160; height: 120; radius: 40; color: "white"; layer.enabled: true
        }
        Text {
            id: glyphMask
            width: 160; height: 120
            text: "O"; color: "white"
            font { pixelSize: 100; bold: true }
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            layer.enabled: true
        }
    }
    StyledFill {
        id: fill
        width: 160; height: 120
        mask: scene.usedMask
        kind: "bevel"; colourA: "#3873a8"
        params: ({ speed: 0, scale: 1, angle: 0, colours: [] })
    }
    // A visible copy lets the test read the encoded field without sampling
    // either the material's colour or a clipped-offscreen item's parent.
    EdgeField { id: probe; x: 180; width: 160; height: 120; mask: scene.usedMask }

    TestCase {
        name: "EdgeFills"
        when: windowShown

        function initTestCase() { failOnWarning(/.*/); Theme.held = true }
        function init() {
            if (scene.GraphicsInfo.api === GraphicsInfo.Software)
                skip("Edge fields require an RHI shader backend")
            scene.hole = true; scene.holeX = 80; scene.usedMask = frameMask
            roundedMask.radius = 40
            fill.mask = Qt.binding(() => scene.usedMask)
            fill.kind = "bevel"; fill.opacity = 1
            fill.params = ({ speed: 0, scale: 1, angle: 0, colours: [] })
            glyphMask.text = "O"; glyphMask.font.pixelSize = 100
            probe.width = 160; roundedMask.width = 160
            fill.lineHeightPx = 0
            probe.coarse = false
            Theme.clock = 0
            wait(40)
        }
        function cleanupTestCase() { Theme.held = false }
        function field() { wait(40); return grabImage(probe) }
        function picture() { wait(40); return grabImage(scene) }
        function distance(image, x, y) { return (image.red(x, y) / 255 + image.green(x, y) / 65025) * 32 }
        function delta(a, b, x, y) {
            return Math.abs(a.red(x, y) - b.red(x, y)) + Math.abs(a.green(x, y) - b.green(x, y))
                 + Math.abs(a.blue(x, y) - b.blue(x, y))
        }

        function test_distance_is_to_the_mask_including_holes() {
            const ring = field()
            fuzzyCompare(distance(ring, 20, 60), 4.5, 0.1, "outer edge")
            fuzzyCompare(distance(ring, 80, 40), 7.5, 0.1, "inner edge of the hole")
            fuzzyCompare(distance(ring, 65, 45), Math.sqrt(18) - 0.5, 0.1, "Euclidean distance round a concave corner")
            fuzzyCompare(distance(ring, 80, 60), 0, 0.01, "empty hole")
            fuzzyCompare(distance(ring, 8, 8), 0, 0.01, "outside the mask")
            // Same Item, same bounds: only its coverage changed. The cached
            // passes must refresh, including the pass downstream of the first.
            scene.hole = false
            const solid = field()
            fuzzyCompare(distance(solid, 80, 40), 28.5, 0.1)
            fuzzyCompare(distance(solid, 80, 60), 31.5, 0.1, "bounded interior")
            scene.hole = true; scene.holeX = 110
            const moved = field()
            fuzzyCompare(distance(moved, 80, 60), 17.5, 0.1, "moving the hole moves the field")
        }
        function test_rounded_corners_and_glyphs_are_not_rectangles() {
            scene.usedMask = roundedMask
            const rounded = field()
            fuzzyCompare(distance(rounded, 2, 2), 0, 0.01)
            const expected = 40 - Math.sqrt(25.5 * 25.5 * 2)
            fuzzyCompare(distance(rounded, 14, 14), expected, 1, "distance to the circular corner, not to x/y=0")
            // Shape changes without changing the radius item's identity.
            roundedMask.radius = 0
            const square = field()
            fuzzyCompare(distance(square, 14, 14), 14.5, 0.1)
            roundedMask.radius = 40
            scene.usedMask = glyphMask
            const o = field()
            fuzzyCompare(distance(o, 80, 60), 0, 0.01, "O's counter")
            glyphMask.text = "B"
            verify(!o.equals(field()), "changing a glyph refreshes its shape field")
        }
        function test_material_follows_the_shape_data() {
            return ["bevel", "contour", "rim", "trace", "tidal", "toon", "doodle", "dome"].map(kind => ({ tag: kind, kind: kind }))
        }
        function test_material_follows_the_shape(data) {
            fill.kind = data.kind
            scene.hole = false
            const solid = picture()
            scene.hole = true
            const ring = picture()
            verify(delta(solid, ring, 66, 60) > 12, "a new inner edge changes the shading of covered pixels")
            compare(ring.pixel(20, 60), solid.pixel(20, 60), "a distant outer edge is unchanged")
            compare(ring.pixel(80, 60), scene.color, "the effect never fills a hole")
            compare(ring.pixel(8, 8), scene.color, "nothing leaks outside the shape")
            const cached = field()
            // Opacity changes paint, never the encoded geometry.
            fill.opacity = 0.5
            const half = picture()
            fuzzyCompare(half.red(66, 60), (ring.red(66, 60) + 16) / 2, 1)
            fuzzyCompare(half.green(66, 60), (ring.green(66, 60) + 24) / 2, 1)
            fuzzyCompare(half.blue(66, 60), (ring.blue(66, 60) + 32) / 2, 1)
            verify(cached.equals(field()), "opacity leaves the distance data alone")
            fill.opacity = 1
            fill.params = ({ speed: 0.3, scale: 1, angle: 0, colours: [] })
            Theme.clock = 4
            verify(!ring.equals(picture()), "the shape lighting/contours animate")
            verify(cached.equals(field()), "animation leaves the cached shape unchanged")
        }
        function test_small_cartoon_glyphs_keep_a_readable_core_data() {
            return ["toon", "comic", "doodle"].map(kind => ({ tag: kind, kind: kind }))
        }
        function test_small_cartoon_glyphs_keep_a_readable_core(data) {
            scene.usedMask = glyphMask
            glyphMask.text = "B"; glyphMask.font.pixelSize = 22
            fill.lineHeightPx = Qt.binding(() => glyphMask.contentHeight)
            fill.kind = data.kind; fill.params = Theme.styledOf(null)
            const geometry = field()
            for (const time of [0, 2, 4]) {
                Theme.clock = time
                const image = picture()
                let total = 0, count = 0
                for (let y = 0; y < 120; ++y) {
                    for (let x = 0; x < 160; ++x) {
                        if (distance(geometry, x, y) < 0.4) continue
                        total += (image.red(x, y) + image.green(x, y) + image.blue(x, y)) / 3
                        count++
                    }
                }
                verify(count > 10, "sample the small glyph's solid coverage")
                verify(total / count > 65, "ink details must not black out the entire glyph at " + time + "s: " + total / count)
            }
        }

        function test_trace_heads_move_along_straight_edges() {
            fill.kind = "trace"
            fill.params = Theme.styledOf(null)
            function headAt(time) {
                Theme.clock = time
                const image = picture()
                let x = 0, light = 0
                for (let i = 24; i < 136; ++i) {
                    const v = image.red(i, 15) + image.green(i, 15) + image.blue(i, 15)
                    if (v > light) { light = v; x = i }
                }
                return ({ x: x, light: light })
            }
            const first = headAt(0.3), next = headAt(0.8)
            verify(first.light > 250 && next.light > 250, "a bright travelling head, not a faint lighting change")
            verify(next.x > first.x + 25, "the head advances along a straight edge: " + first.x + " -> " + next.x)
        }
        function test_tidal_level_moves_but_never_fills_counters() {
            fill.kind = "tidal"
            fill.params = Theme.styledOf(null)
            const low = picture()
            Theme.clock = 2
            const high = picture()
            verify(high.green(80, 35) > low.green(80, 35) + 30, "liquid rises into previously dry coverage")
            compare(low.pixel(80, 60), scene.color)
            compare(high.pixel(80, 60), scene.color, "the letter hole stays empty throughout the wave")
        }
        function test_live_clock_data() {
            return ["contour", "rim", "trace", "tidal", "toon", "doodle"].map(kind => ({ tag: kind, kind: kind }))
        }
        function test_live_clock(data) {
            // Snapshots at hand-assigned times prove shader maths, not that
            // a selected style actually animates. Exercise the real driver
            // using a palette entry with the default (nonzero) speed.
            const previous = Theme.p.text
            try {
                fill.kind = data.kind
                fill.params = Theme.styledOf(null)
                Theme.p.text = ({ colour: "#3873a8", source: data.kind })
                Theme.pChanged()
                verify(Theme.anyAnimated)
                Theme.held = false
                tryVerify(() => Theme.clock > 0.05, 1000, "the shared clock starts without opening a picker")
                const first = picture()
                wait(600)
                verify(!first.equals(picture()), "the effect moves under the real animation clock")
                fill.params = ({ speed: 0, scale: 1, angle: 0, colours: [] })
                const still = picture(), time = Theme.clock
                wait(160)
                verify(Theme.clock > time, "other moving styles can keep the clock running")
                verify(still.equals(picture()), "zero speed freezes this material independently")
            } finally {
                Theme.held = true
                if (previous === undefined) delete Theme.p.text
                else Theme.p.text = previous
                Theme.pChanged()
            }
        }

        function test_no_field_for_rectangles_or_pattern_only_fills() {
            const cache = findChild(fill, "edgeFieldCache")
            verify(cache.active)
            fill.kind = "opal"
            tryCompare(cache, "active", false)
            fill.kind = "bevel"; fill.mask = null
            tryCompare(cache, "active", false)
            // An analytic rectangle and a full rectangular mask agree away
            // from subpixel coverage. Both include all four texture bounds.
            const analytic = picture()
            roundedMask.radius = 0
            fill.mask = roundedMask
            const masked = picture()
            verify(delta(analytic, masked, 2, 60) < 4)
            verify(delta(analytic, masked, 80, 2) < 4)
            roundedMask.radius = 40
            fill.mask = Qt.binding(() => scene.usedMask)
        }
        // The field keeps its texture while the size moves: re-running two
        // nested passes each drag step is a quarter of a billion fetches on a
        // page-sized item. It stretches until it re-runs, 100ms after the last
        // change.
        function test_the_field_freezes_while_the_size_moves() {
            scene.usedMask = roundedMask
            const at160 = field()
            probe.width = 320; roundedMask.width = 320
            wait(40)
            verify(probe.settling, "a size that is still moving")
            const held = grabImage(probe)
            fuzzyCompare(distance(held, 28, 14), distance(at160, 14, 14), 0.6,
                         "the same data across twice the width, not a new search")
            tryVerify(() => !probe.settling, 1000, "and it settles after the last change")
            const at320 = field()
            fuzzyCompare(distance(at320, 28, 14), 40 - Math.sqrt(11.5 * 11.5 + 25.5 * 25.5), 1,
                         "then the corner is measured at the size that stuck")
            probe.width = 160; roundedMask.width = 160
            tryVerify(() => !probe.settling, 1000)
        }

        // A half-resolution field reports the same distances: both uniforms are
        // in target texels, so decoding with the full-resolution reach gives
        // logical pixels, within the half-texel bias (a whole logical pixel
        // here).
        function test_a_coarse_field_reports_the_same_distances() {
            scene.usedMask = roundedMask
            const fine = field()
            probe.coarse = true
            const coarse = field()
            fuzzyCompare(distance(coarse, 20, 60), distance(fine, 20, 60), 1.1, "a straight edge")
            fuzzyCompare(distance(coarse, 14, 14), distance(fine, 14, 14), 1.6, "a rounded corner")
            fuzzyCompare(distance(coarse, 2, 2), 0, 0.01, "still nothing outside the shape")
            verify(!fine.equals(coarse), "and it really is a different texture")
        }

        // A gradient's bands are straight, so points equally far along its axis
        // match whatever their offset across it; a dome's bands curve round the
        // shape, so the same two points differ.
        function test_a_dome_bends_its_bands_round_the_shape() {
            // A 120px circle. The mask is stretched onto the fill's rect, so
            // both have to be square for the shape to be round.
            scene.usedMask = roundedMask
            roundedMask.width = 120; roundedMask.height = 120; roundedMask.radius = 60
            fill.width = 120; fill.height = 120
            // Two points the SAME distance along the 45 axis and different
            // distances across it — so a gradient, whose bands are straight
            // lines perpendicular to its axis, must give them one colour.
            const ax = 81, ay = 81            // 30px out along the axis
            const bx = 110, by = 53           // same, then 40px across it
            fill.kind = "gradient"
            fill.params = ({ speed: 0, scale: 1, angle: 45, colours: ["#101010"], fit: 1 })
            const flat = picture()
            fuzzyCompare(flat.red(ax, ay), flat.red(bx, by), 3,
                         "a gradient gives one colour to a whole band")
            fill.kind = "dome"
            fill.params = ({ speed: 0, scale: 1, angle: 45, colours: ["#101010"],
                             depth: 1, light: 0.5, bias: 0, spread: 1,
                             spec: 0, gloss: 16, bounce: 0, reach: 0 })
            const lit = picture()
            // ...and a dome must not: the two face the light by different
            // amounts, because how far the surface is turned is what it
            // walks its ramp by.
            verify(Math.abs(lit.red(ax, ay) - lit.red(bx, by)) > 12,
                   "a dome's bands bend round the shape instead")
            roundedMask.width = 160; roundedMask.height = 120; roundedMask.radius = 40
            fill.width = 160; fill.height = 120
        }

        function test_initial_geometry_does_not_wait_for_the_slow_tick() {
            // A fill constructed before it has a window must already have
            // its real size, or its normal samples are a whole texture apart.
            const component = Qt.createComponent("../../src/qml/components/StyledFill.qml")
            compare(component.status, Component.Ready)
            const unattached = component.createObject(null, { width: 91, height: 27, kind: "bevel" })
            verify(unattached !== null)
            compare(unattached.geo0.z, 91)
            compare(unattached.geo0.w, 27)
            unattached.destroy()
        }
    }
}
