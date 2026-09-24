import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

Rectangle {
    id: scene
    width: 240; height: 160
    color: "#26313c"
    Item {
        width: 0; height: 0; clip: true
        Rectangle { id: shape; width: fill.width; height: fill.height; radius: Math.min(20, height / 2)
                    color: "white"; layer.enabled: true }
    }
    StyledFill {
        id: fill
        x: 10; y: 10; width: 200; height: 100
        mask: shape
        kind: "toon"
        colourA: "#f7c0d8"
        // Surface/BlendSurface ask for this optimization. Thin drawn ink
        // must opt out, rather than tracing the half-resolution stair steps.
        coarseField: true
    }
    TestCase {
        name: "ToonFills"
        when: windowShown
        function initTestCase() { failOnWarning(/.*/); Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function init() {
            if (scene.GraphicsInfo.api === GraphicsInfo.Software) skip("Toon needs an RHI shader backend")
            fill.kind = "toon"; fill.maskKey = ""; fill.layers = null
            fill.width = 200; fill.height = 100
            fill.params = ({ speed: 0, scale: 1, angle: 0, colours: [],
                             own: { edgeAuto: 0, edge: 3, ink: 1.15, relief: 0.55 } })
            Theme.clock = 0
            wait(160)
        }
        function picture() { wait(50); return grabImage(fill) }
        function light(image, x, y) { return Math.max(image.red(x,y), image.green(x,y), image.blue(x,y)) }

        function test_thin_ink_gets_full_resolution_geometry() {
            verify(fill.field !== null)
            compare(fill.field.coarse, false)
            fill.maskKey = "toon-test-rounded"
            wait(80)
            verify(fill.sharedField !== null)
            compare(fill.sharedField.coarse, false)
            fill.kind = "bevel"
            wait(80)
            compare(fill.sharedField.coarse, true, "soft materials retain the cheaper field")
        }
        function test_outline_does_not_disappear_on_the_lit_sides_data() {
            return [{ tag: "card", w: 200, h: 100 }, { tag: "pill", w: 81, h: 28 },
                    { tag: "fractional", w: 69.5, h: 25.5 }, { tag: "round", w: 28, h: 28 }]
        }
        function test_outline_does_not_disappear_on_the_lit_sides(data) {
            fill.width = data.w; fill.height = data.h
            wait(160)
            const image = picture()
            const cx = Math.floor(data.w / 2), cy = Math.floor(data.h / 2)
            for (const p of [[cx,0],[0,cy],[Math.floor(data.w)-1,cy],[cx,Math.floor(data.h)-1]]) {
                verify(light(image,p[0],p[1]) < 80, "continuous dark ink at " + p + ": " + light(image,p[0],p[1]))
            }
        }
        function test_corner_ink_has_no_bright_gaps() {
            const image = picture()
            let count = 0
            for (let y = 0; y < 20; ++y) {
                for (let x = 0; x < 20; ++x) {
                    const d = 20 - Math.hypot(20 - x - 0.5, 20 - y - 0.5)
                    if (d < 0.5 || d > 0.95 || image.alpha(x,y) < 250) continue
                    verify(light(image,x,y) < 110, "ink gap on the round corner at " + x + "," + y)
                    count++
                }
            }
            verify(count >= 8, "sample fully covered pixels along the curve")
        }
        function test_flat_face_keeps_the_chosen_colour() {
            const image = picture()
            fuzzyCompare(image.red(100,50), 247, 2)
            fuzzyCompare(image.green(100,50), 192, 2)
            fuzzyCompare(image.blue(100,50), 216, 2)
        }
        function test_shadow_is_coloured_not_a_second_black_outline() {
            const image = picture()
            verify(image.green(196,50) > 85, "the shadow must retain the pink, not turn to black")
            verify(image.green(196,50) < 180, "there is still a cel shadow")
            verify(image.green(3,50) > image.green(196,50) + 20, "lighting distinguishes the two sides")
        }
        function test_zero_ink_removes_the_pen_without_a_jump() {
            const outlined = picture()
            let params = JSON.parse(JSON.stringify(fill.params))
            params.own.ink = 0
            fill.params = params
            const none = picture()
            for (const p of [[100,0],[0,50],[199,50],[100,99]])
                verify(light(none,p[0],p[1]) > light(outlined,p[0],p[1]) + 100, "zero ink removes every side")
            params = JSON.parse(JSON.stringify(fill.params))
            params.own.ink = 0.001
            fill.params = params
            const almostNone = picture()
            for (let y = 0; y < 100; y += 2)
                for (let x = 0; x < 200; x += 2)
                    verify(Math.abs(light(none,x,y) - light(almostNone,x,y)) <= 3, "no discontinuity at zero ink")
        }
        function test_toon_in_a_stack_also_gets_the_fine_field() {
            fill.kind = "bevel"
            fill.layers = [{ colour: "#eeeeee" }, { source: "toon", colour: "#f7c0d8", params: fill.params }]
            wait(80)
            compare(fill.field.coarse, false)
        }
        function test_new_shading_controls_leave_pen_and_face_alone() {
            const before = picture()
            const params = JSON.parse(JSON.stringify(fill.params))
            Object.assign(params.own, { softness: 1, shine: 0, bulge: 3 })
            fill.params = params
            const after = picture()
            verify(!before.equals(after), "the shoulder shading changes")
            compare(before.pixel(100,50), after.pixel(100,50), "the reading face keeps its chosen colour")
            compare(before.pixel(100,0), after.pixel(100,0), "the outline stays dark")
        }
        function test_ink_and_face_stay_put_when_the_light_turns() {
            const before = picture()
            fill.params = ({ speed: 0.3, scale: 1, angle: 0, colours: [],
                             own: { edgeAuto: 0, edge: 3, ink: 1.15, relief: 0.55 } })
            Theme.clock = 3
            const after = picture()
            verify(!before.equals(after), "cel lighting still moves")
            compare(before.pixel(100,50), after.pixel(100,50), "no lighting flicker over reading areas")
            compare(before.pixel(100,0), after.pixel(100,0), "the pen is not a lighting effect")
        }
    }
}
