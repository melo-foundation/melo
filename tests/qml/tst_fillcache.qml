import QtQuick
import QtQuick.Window
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// One coverage mask and one edge field per shape per window: what the cache
// hands out, how long it holds it, and when it lets go.
Item {
    id: scene
    width: 200; height: 200
    readonly property string key: "m:100:60:8:8:8:8"
    readonly property var shape: ({ width: 100, height: 60, radius: 8,
                                    topLeftRadius: 8, topRightRadius: 8,
                                    bottomLeftRadius: 8, bottomRightRadius: 8 })

    // A shape-aware fill over a rounded rectangle, drawn twice: once with its
    // own field and once through the cache's. The picture is the assertion.
    Item {
        width: 0; height: 0; clip: true
        Rectangle { id: roundedMask; width: 80; height: 60; radius: 14
                    color: "white"; layer.enabled: true }
    }
    StyledFill {
        id: ownField
        y: 100; width: 80; height: 60
        mask: roundedMask
        kind: "bevel"; colourA: "#3873a8"
        params: ({ speed: 0, scale: 1, angle: 0, colours: [] })
    }
    StyledFill {
        id: sharedFieldFill
        x: 100; y: 100; width: 80; height: 60
        mask: roundedMask
        maskKey: "m:80:60:14:14:14:14"
        kind: "bevel"; colourA: "#3873a8"
        params: ({ speed: 0, scale: 1, angle: 0, colours: [] })
    }

    TestCase {
        name: "FillCache"
        when: windowShown

        function cache() { return Theme.fillCache(scene.Window.window) }

        function test_the_cache_is_one_item_under_the_window() {
            const c = cache()
            verify(c, "a window has a cache")
            compare(cache(), c, "and only ever the one")
            compare(c.parent, scene.Window.window.contentItem)
            compare(c.width, 0, "zero-sized: what it renders is drawn nowhere")
        }

        function test_one_mask_per_shape_held_by_its_readers() {
            const c = cache()
            const a = c.mask(scene.key, scene.shape)
            verify(a, "a shape that has never been asked for is built")
            const b = c.mask(scene.key, scene.shape)
            compare(b, a, "and the second reader gets the same item")
            compare(a.width, 100); compare(a.height, 60); compare(a.radius, 8)

            c.release(scene.key)
            wait(50)
            verify(c.entries[scene.key] !== undefined, "one reader left, so it stays")
            c.release(scene.key)
            verify(c.entries[scene.key] !== undefined, "and a grace after the last one lets go")
            wait(2200)
            verify(c.entries[scene.key] !== undefined, "nothing sweeps on a clock")
            // ...and the sweep is the next shape asked for
            c.mask("m:33:33:0:0:0:0", ({ width: 33, height: 33 }))
            verify(c.entries[scene.key] === undefined, "then it goes")
            c.release("m:33:33:0:0:0:0")
        }

        // A different shape is a different item, which is the whole of the key.
        function test_a_different_size_is_a_different_mask() {
            const c = cache()
            const a = c.mask("m:40:40:0:0:0:0", ({ width: 40, height: 40 }))
            const b = c.mask("m:41:40:0:0:0:0", ({ width: 41, height: 40 }))
            verify(a !== b)
            compare(a.width, 40); compare(b.width, 41)
            c.release("m:40:40:0:0:0:0"); c.release("m:41:40:0:0:0:0")
        }

        // The shared field is the same field. A fill that names a mask key
        // reads the window's copy instead of building its own, and the
        // distances (the whole picture for a shape kind) come out the same to
        // the pixel.
        function test_a_shared_field_draws_what_an_own_field_draws() {
            if (scene.GraphicsInfo.api === GraphicsInfo.Software)
                skip("Edge fields require an RHI shader backend")
            Theme.held = true
            Theme.clock = 0
            try {
                verify(sharedFieldFill.fieldKey.length > 0, "the key names a shared shape")
                tryVerify(() => sharedFieldFill.sharedField !== null, 2000)
                compare(findChild(sharedFieldFill, "edgeFieldCache").active, false,
                        "and it builds none of its own")
                verify(findChild(ownField, "edgeFieldCache").active, "while this one does")
                // under a loaded ctest run the shared field can land a few
                // frames late, so wait for the two to agree before checking
                // every sample
                const same = () => {
                    const o = grabImage(ownField), s = grabImage(sharedFieldFill)
                    for (let y = 2; y < 58; y += 7)
                        for (let x = 2; x < 78; x += 7)
                            if (String(s.pixel(x, y)) !== String(o.pixel(x, y))) return false
                    return true
                }
                tryVerify(same, 2000)
                const own = grabImage(ownField), shared = grabImage(sharedFieldFill)
                for (let y = 2; y < 58; y += 7)
                    for (let x = 2; x < 78; x += 7)
                        compare(shared.pixel(x, y), own.pixel(x, y), "at " + x + "," + y)
            } finally { Theme.held = false }
        }

        // A surface that goes and comes back within the grace — a list
        // recycling its delegates — finds what it just let go of.
        function test_the_grace_survives_a_release_and_a_re_acquire() {
            const c = cache()
            const a = c.mask(scene.key, scene.shape)
            c.release(scene.key)
            wait(200)
            const b = c.mask(scene.key, scene.shape)
            compare(b, a, "not rebuilt")
            wait(2500)
            c.mask("m:34:34:0:0:0:0", ({ width: 34, height: 34 }))
            verify(c.entries[scene.key] !== undefined, "and a sweep does not take one that is held")
            c.release("m:34:34:0:0:0:0")
            c.release(scene.key)
        }
    }
}
