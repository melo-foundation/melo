import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The normal offscreen runner uses Qt's software scene graph, which cannot
// draw ShaderEffect. Exercise real shader compilation/rendering locally with:
// QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
//     qmltestrunner-qt6 -input tests/qml/tst_styledfills.qml
Rectangle {
    id: scene
    width: 320; height: 240
    color: "#101820"

    StyledFill {
        id: fill
        anchors.fill: parent
        local: true
        colourA: "#315080"
    }
    Item {
        width: 0; height: 0; clip: true
        Item {
            id: coverage
            width: scene.width; height: scene.height
            layer.enabled: true
            Rectangle { width: parent.width / 2; height: parent.height; color: "white" }
        }
    }

    TestCase {
        name: "StyledFills"
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
            fill.mask = null; fill.visible = true; fill.opacity = 1; fill.colourA = "#315080"
            fill.layers = null; fill.kind = "rainbow"
            scene.width = 320; scene.height = 240
        }

        function paint(speed, time, scale, angle, colours) {
            fill.params = ({ speed: speed, scale: scale === undefined ? 1 : scale,
                             angle: angle === undefined ? 0 : angle, colours: colours || [] })
            Theme.clock = time
            wait(40)
            return grabImage(scene)
        }
        function pixelChange(a, b) {
            let sum = 0, count = 0, changed = 0
            for (let y = 3; y < a.height; y += 5) {
                for (let x = 3; x < a.width; x += 5) {
                    const d = (Math.abs(a.red(x, y) - b.red(x, y)) + Math.abs(a.green(x, y) - b.green(x, y))
                             + Math.abs(a.blue(x, y) - b.blue(x, y))) / 3
                    sum += d; count++; if (d > 12) changed++
                }
            }
            return ({ mean: sum / count, fraction: changed / count })
        }
        function shot(time) { Theme.clock = time; wait(40); return grabImage(scene) }
        function differs(a, b, x, y) {
            return Math.abs(a.red(x, y) - b.red(x, y)) + Math.abs(a.green(x, y) - b.green(x, y))
                 + Math.abs(a.blue(x, y) - b.blue(x, y)) > 12
        }

        // A stack of one, and every caller still names one kind: the stack
        // renderer has to draw those pixel for pixel as the single-kind path
        // does, or the difference is visible on every themed surface in melo.
        function test_a_stack_of_one_is_the_fill_it_replaces() {
            fill.kind = "opal"
            fill.params = ({ speed: 0, scale: 1, angle: 0, colours: ["#ffd25a", "#ff30a0"] })
            const scalar = shot(0)
            fill.layers = Theme.layersOf({ source: "opal", colour: "#315080",
                                           params: { speed: 0, scale: 1, angle: 0,
                                                     colours: ["#ffd25a", "#ff30a0"] } })
            verify(shot(0).equals(scalar), "a stack of one draws what the scalar path drew")
        }

        function test_a_second_layer_draws_over_the_first() {
            const base = ({ source: "opal", colour: "#315080", params: { speed: 0, scale: 1, angle: 0 } })
            fill.layers = Theme.layersOf({ layers: [base] })
            const one = shot(0)
            fill.layers = Theme.layersOf({ layers: [base, { source: "colour", colour: "#ff3020" }] })
            verify(!shot(0).equals(one), "the layer above draws over the one below")
            fill.layers = Theme.layersOf({ layers: [base, { source: "colour", colour: "#ff3020", opacity: 0 }] })
            verify(shot(0).equals(one), "a layer at zero opacity leaves the one below it alone")
        }

        // A flat colour over a fill covers it, and which one is on top is the
        // whole point of a stack. A plain colour is stored as a bare string and
        // is still a layer, and a stack of nothing but colours still reaches
        // this renderer.
        function test_a_plain_colour_layer_covers_what_is_under_it() {
            const opal = ({ colour: "#ff0000", source: "opal", params: ({ speed: 0 }) })
            fill.layers = Theme.layersOf({ layers: [opal, "#000000"] })
            const covered = shot(0)
            compare(covered.red(160, 120), 0); compare(covered.green(160, 120), 0)
            compare(covered.blue(160, 120), 0)
            fill.layers = Theme.layersOf({ layers: ["#000000", opal] })
            verify(!shot(0).equals(covered), "and the other way round is the fill, not the colour")

            // a stack of nothing but colours is still a stack
            fill.layers = Theme.layersOf({ layers: ["#ff0000", "#0000ff"] })
            const blueOnTop = shot(0)
            compare(blueOnTop.blue(160, 120), 255); compare(blueOnTop.red(160, 120), 0)
            fill.layers = Theme.layersOf({ layers: ["#0000ff", "#ff0000"] })
            const redOnTop = shot(0)
            compare(redOnTop.red(160, 120), 255); compare(redOnTop.blue(160, 120), 0)

            // and a colour's own alpha is the layer's, not the caller's
            fill.layers = Theme.layersOf({ layers: ["#ff0000", "#800000ff"] })
            const half = shot(0)
            verify(Math.abs(half.red(160, 120) - 127) < 4, "half red: " + half.red(160, 120))
            verify(Math.abs(half.blue(160, 120) - 128) < 4, "half blue: " + half.blue(160, 120))
        }

        // Overlay, soft-light, difference and the four non-separable modes read
        // what is below, which BlendRect cannot; inside a stack that is a
        // texture we drew. Checked by hand against the W3C formulas on a mid
        // grey backdrop.
        function test_the_shader_blend_modes_data() {
            // backdrop 0.5 grey, source as given -> the channel value expected
            return [
                { tag: "overlay",     mode: "overlay",      src: "#ff000000", want: 0 },
                { tag: "overlay-hi",  mode: "overlay",      src: "#ffffffff", want: 255 },
                { tag: "hard-light",  mode: "hard light",   src: "#ff000000", want: 0 },
                { tag: "difference",  mode: "difference",   src: "#ffffffff", want: 128 },
                { tag: "exclusion",   mode: "exclusion",    src: "#ffffffff", want: 128 },
                { tag: "dodge",       mode: "colour dodge", src: "#ff000000", want: 128 },
                { tag: "burn",        mode: "colour burn",  src: "#ffffffff", want: 128 },
                { tag: "luminosity",  mode: "luminosity",   src: "#ffffffff", want: 255 },
                { tag: "colour",      mode: "colour",       src: "#ffffffff", want: 128 },
                // past the W3C set: Krita's and GIMP's, against their formulas
                { tag: "linear-burn",   mode: "linear burn",    src: "#ffffffff", want: 128 },
                { tag: "linear-dodge",  mode: "linear dodge",   src: "#ff404040", want: 191 },
                { tag: "linear-light",  mode: "linear light",   src: "#ffffffff", want: 255 },
                { tag: "linear-light0", mode: "linear light",   src: "#ff000000", want: 0 },
                { tag: "vivid-light",   mode: "vivid light",    src: "#ffffffff", want: 255 },
                { tag: "pin-light",     mode: "pin light",      src: "#ff000000", want: 0 },
                { tag: "hard-mix",      mode: "hard mix",       src: "#ffffffff", want: 255 },
                { tag: "hard-mix0",     mode: "hard mix",       src: "#ff000000", want: 0 },
                { tag: "divide",        mode: "divide",         src: "#ff808080", want: 255 },
                { tag: "divide1",       mode: "divide",         src: "#ffffffff", want: 128 },
                { tag: "grain-extract", mode: "grain extract",  src: "#ff808080", want: 128 },
                { tag: "grain-merge",   mode: "grain merge",    src: "#ff808080", want: 128 },
                { tag: "geo-mean",      mode: "geometric mean", src: "#ffffffff", want: 180 },
                { tag: "negation",      mode: "negation",       src: "#ffffffff", want: 128 },
                { tag: "reflect",       mode: "reflect",        src: "#ff808080", want: 128 },
                { tag: "glow",          mode: "glow",           src: "#ff808080", want: 128 },
                { tag: "allanon",       mode: "allanon",        src: "#ffffffff", want: 191 }
            ]
        }
        function test_the_shader_blend_modes(data) {
            fill.mask = null
            fill.layers = Theme.layersOf({ layers: ["#ff808080",
                                                    ({ colour: data.src, blend: data.mode })] })
            const img = shot(0)
            const got = img.red(160, 120)
            verify(Math.abs(got - data.want) <= 3,
                   data.mode + " over mid grey: got " + got + ", expected " + data.want)
        }

        // The six the GPU can do are still done by the GPU: a stack that names
        // only those must not build a chain of offscreen passes.
        function test_only_a_shader_mode_chains_the_stack() {
            fill.layers = Theme.layersOf({ layers: ["#ff808080",
                                                    ({ colour: "#ffffffff", blend: "screen" })] })
            verify(!fill.chained, "screen is a blend factor")
            fill.layers = Theme.layersOf({ layers: ["#ff808080",
                                                    ({ colour: "#ffffffff", blend: "overlay" })] })
            verify(fill.chained, "overlay is not")
            fill.layers = Theme.layersOf({ layers: ["#ff808080", "#ffffffff"] })
            verify(!fill.chained, "and no blend at all is not")
        }

        // The bottom layer needs no rung: its texture is what the first rung
        // composites onto. A translucent one keeps its rung, the only carrier
        // of its own alpha.
        function test_the_chain_drops_the_rung_the_bottom_layer_does_not_need() {
            fill.mask = null
            fill.layers = Theme.layersOf({ layers: ["#ffff0000",
                                                    ({ colour: "#ffffffff", blend: "difference" })] })
            verify(fill.chained)
            verify(fill.bottomIsTexture, "an opaque bottom layer is the backdrop itself")
            const opaque = shot(0)
            compare(opaque.red(160, 120), 0, "white differenced against opaque red")
            fill.layers = Theme.layersOf({ layers: ["#80ff0000",
                                                    ({ colour: "#ffffffff", blend: "difference" })] })
            verify(!fill.bottomIsTexture, "a translucent one keeps the rung that applies its alpha")
            const faded = shot(0)
            verify(Math.abs(faded.red(160, 120) - 128) < 4,
                   "half the red is left to difference against: " + faded.red(160, 120))
        }

        // A rim in one fill over an interior in another. The band is measured
        // from the drawn coverage, not from the item, so it follows a shape.
        function test_a_mask_mode_confines_a_layer_to_the_edge() {
            fill.mask = coverage
            const body = ({ source: "colour", colour: "#203040" })
            fill.layers = Theme.layersOf({ layers: [body] })
            const plain = shot(0)
            fill.layers = Theme.layersOf({ layers: [body, { source: "colour", colour: "#ff3020",
                                                            mask: "edge", maskDist: 4 }] })
            const rim = shot(0)
            verify(differs(rim, plain, 2, 120), "the band paints within 4px of the edge")
            verify(!differs(rim, plain, 80, 120), "and leaves the interior alone")
            fill.layers = Theme.layersOf({ layers: [body, { source: "colour", colour: "#ff3020",
                                                            mask: "core", maskDist: 4 }] })
            const core = shot(0)
            verify(!differs(core, plain, 2, 120), "core leaves the band at the edge alone")
            verify(differs(core, plain, 80, 120), "and paints everything beyond it")
            // still masked: neither mode paints outside the coverage
            fill.visible = false
            const ground = shot(0)
            fill.visible = true
            verify(!differs(core, ground, 240, 120), "nothing draws outside the coverage")
        }

        // Palette entry -> role -> renderer, end to end: a store-added white
        // `colour`, layers as a QVariantList that Array.isArray refuses, or a
        // renderer not handed them would each paint flat white.
        function test_a_role_holding_a_stack_draws_it() {
            const before = shot(0)
            // as it comes back from the settings store: array-LIKE, not an Array
            const fromStore = ({ 0: ({ colour: "#9a4b2949", source: "brushed",
                                       params: ({ speed: 0, scale: 1, angle: 0 }) }),
                                 1: ({ colour: "#653862", source: "mercury",
                                       params: ({ speed: 0, scale: 0.82, angle: 174,
                                                  colours: ["#514a1d", "#00c924", "#51c924",
                                                            "#87c924", "#93522f", "#000000"] }) }),
                                 length: 2 })
            const role = Theme.role("window")
            fill.mask = null
            fill.kind = Theme.sourceOf(({ layers: fromStore }))
            fill.params = Theme.styledOf(({ layers: fromStore }))
            fill.colourA = Theme.colorOf(({ layers: fromStore }), "#ffffff")
            fill.layers = Theme.layersOf(({ layers: fromStore }))
            const after = shot(0)
            verify(!after.equals(before), "the stack draws something")
            let lo = 765, hi = 0, white = 0, n = 0
            for (let y = 3; y < after.height; y += 5)
                for (let x = 3; x < after.width; x += 5) {
                    const v = after.red(x, y) + after.green(x, y) + after.blue(x, y)
                    lo = Math.min(lo, v); hi = Math.max(hi, v); n++
                    if (v === 765) white++
                }
            verify(hi - lo > 60, "a stack of two fills, not one flat colour: " + lo + ".." + hi)
            verify(white / n < 0.5, "and not a white surface: " + white + "/" + n)
            fill.layers = null
        }

        function test_default_motion_data() {
            const rows = []
            for (const kind of ["agate", "mercury", "gyroid", "kaleido", "raster", "cloud", "comic"])
                for (const tile of [false, true])
                    rows.push({ tag: kind + (tile ? "_tile" : "_surface"), kind: kind, tile: tile })
            return rows
        }
        function test_default_motion(data) {
            // A different image could mean one changed pixel, which a fill
            // that mostly slides a frozen texture passes. Require visible movement at DEFAULT speed, including 60px tiles,
            // and much smaller changes between neighbouring 60Hz frames.
            fill.kind = data.kind
            scene.width = data.tile ? 60 : 320; scene.height = data.tile ? 26 : 240
            const minMean = ({ agate: 30, mercury: data.tile ? 25 : 35, gyroid: 12, kaleido: 18, raster: 8, cloud: 2, comic: 10 })[data.kind]
            const minFraction = ({ agate: 0.6, mercury: 0.3, gyroid: 0.35, kaleido: 0.6, raster: 0.15, cloud: 0.02, comic: 0.2 })[data.kind]
            for (const start of [0, 6, 14]) {
                const before = paint(0.3, start), after = paint(0.3, start + 1)
                const second = pixelChange(before, after)
                verify(second.mean > minMean, "visible change at " + start + "s: " + JSON.stringify(second))
                verify(second.fraction > minFraction, "motion covers the material: " + JSON.stringify(second))
                const frame = pixelChange(after, paint(0.3, start + 1 + 1 / 60))
                verify(frame.mean < second.mean * 0.3, "continuous motion, not frame-to-frame flicker")
            }
        }

        // A kind's own options reach the shader. A table entry with
        // no `slot` wired up, or one wired to a uniform the kind never reads,
        // is a slider that moves and changes nothing.
        function test_a_kinds_own_option_changes_the_picture_data() {
            const rows = []
            // Image options need a real source and have their own RHI suite.
            for (const kind of Object.keys(Theme.fillOptionTables).filter(k => k !== "image"))
                for (const o of Theme.fillOptions(kind))
                    rows.push({ tag: kind + "." + o.name, kind: kind, opt: o })
            return rows
        }
        // a coloured ramp for a filter to work on: a filter alone has nothing
        // under it and draws nothing, whatever its options say
        readonly property var ramp: ({ colour: "#808080", source: "gradient",
                                       params: ({ speed: 0, scale: 1, angle: 0,
                                                  colours: ["#3060ff", "#ff6030"] }) })
        function test_a_kinds_own_option_changes_the_picture(data) {
            const o = data.opt, isF = Theme.isFilter(data.kind)
            fill.kind = isF ? "colour" : data.kind
            const at = (p) => {
                if (isF) fill.layers = Theme.layersOf({ layers: [ramp, ({ source: data.kind, params: p })] })
                else fill.params = p
                Theme.clock = o.motion ? 3 : 0
                wait(40)
                return grabImage(scene)
            }
            // Motion options need a running clock; testing wind at time zero
            // would mistake a working slider for a disconnected uniform.
            // an option shown only under another's setting is read only there
            const gate = o.when || ({})
            // A lever that places a stop needs stops: with an empty palette
            // there is nothing for it to move and it would read as dead.
            const pal = o.needsStops ? ["#3060ff", "#ff6030", "#20c040",
                                        "#c040c0", "#40c0c0", "#c0c040"] : []
            const withOpt = (v) => {
                const p = ({ speed: o.motion ? 0.3 : 0, scale: 1, angle: 0, colours: pal.slice() })
                for (const k in gate) p[k] = gate[k]
                p[o.name] = v; return p
            }
            const base = at(withOpt(o.value))
            // the end of the range furthest from the default. A toggle is not
            // asked: its two words hold the same picture by design — literal
            // defaults are what auto gives at 100% — and its rows are asked.
            if (!Theme.isList(o.toggle)) {
                // a full turn's two ends are the same angle
                const far = o.to - o.from >= 360 && o.unit === "°" ? o.from + 180
                          : Math.abs(o.value - o.from) > Math.abs(o.to - o.value) ? o.from : o.to
                verify(!at(withOpt(far)).equals(base), o.name + " at " + far + " draws the same as at " + o.value)
            }
            // and an entry that names no value draws exactly as the default
            const bare = ({ speed: o.motion ? 0.3 : 0, scale: 1, angle: 0, colours: pal.slice() })
            for (const k in gate) bare[k] = gate[k]
            verify(at(bare).equals(base), o.name + ": naming nothing is not the default")
            fill.layers = null
        }

        function test_cloud_wind_and_billow_are_independent() {
            fill.kind = "cloud"
            const at = (wind, billow, time) => {
                fill.params = { speed: 0.3, scale: 1, angle: 0, own: { wind: wind, billow: billow } }
                return shot(time)
            }
            verify(at(0, 0, 0).equals(at(0, 0, 4)), "both off freezes the cloud despite a running clock")
            verify(!at(0, 1, 0).equals(at(0, 1, 4)), "billow changes the cloud without drifting it")
            verify(!at(1, 0, 0).equals(at(1, 0, 4)), "wind moves a non-billowing cloud")
        }
        function test_cloud_zero_density_is_clear_sky() {
            fill.kind = "cloud"
            for (const softness of [0.2, 1, 2]) {
                fill.params = { speed: 0.3, own: { density: 0, softness: softness } }
                const image = shot(3)
                compare(image.pixel(10,10), image.pixel(160,120), "no stray puffs at zero density")
                compare(image.pixel(310,230), image.pixel(160,120))
            }
        }
        function test_bevel_can_sink_and_flatten() {
            fill.kind = "bevel"
            const at = (inset, height) => {
                fill.params = { speed: 0, own: { edgeAuto: 0, edge: 6, shine: 0, inset: inset, height: height } }
                return shot(0)
            }
            const raised = at(0,1), sunk = at(1,1)
            verify(raised.green(1,120) > sunk.green(1,120) + 30, "inset reverses the lit side")
            verify(sunk.green(318,120) > raised.green(318,120) + 30)
            compare(raised.pixel(160,120), sunk.pixel(160,120), "inset does not recolour the flat face")
            const flat = at(0,0)
            compare(flat.pixel(1,120), flat.pixel(160,120), "zero height also removes edge tint and shine")
        }

        // The filters, against their formulas. Each takes the layers under it
        // and changes them; here that is one flat colour, so the answer is a
        // number.
        function test_the_filters_data() {
            const grey = "#ff808080", red = "#ffff0000", dark = "#ff404040"
            return [
                { tag: "posterize-2",  under: grey, kind: "posterize", p: { levels: 2 },  want: [255, 255, 255] },
                { tag: "posterize-3",  under: grey, kind: "posterize", p: { levels: 3 },  want: [128, 128, 128] },
                { tag: "threshold-lo", under: grey, kind: "threshold", p: { level: 0.4 }, want: [255, 255, 255] },
                { tag: "threshold-hi", under: grey, kind: "threshold", p: { level: 0.6 }, want: [0, 0, 0] },
                { tag: "invert",       under: grey, kind: "invert",    p: {},             want: [127, 127, 127] },
                { tag: "grey",         under: red,  kind: "grey",      p: {},             want: [77, 77, 77] },
                { tag: "sepia",        under: grey, kind: "sepia",     p: {},             want: [173, 154, 120] },
                { tag: "hueshift-180", under: red,  kind: "hueshift",  p: { degrees: 180 }, want: [0, 170, 170] },
                { tag: "contrast-3",   under: dark, kind: "contrast",  p: { amount: 3 },  want: [0, 0, 0] },
                { tag: "saturate-0",   under: red,  kind: "saturate",  p: { amount: 0 },  want: [77, 77, 77] }
            ]
        }
        function test_the_filters(data) {
            fill.mask = null
            fill.layers = Theme.layersOf({ layers: [data.under, ({ source: data.kind, params: data.p })] })
            const img = shot(0)
            const got = [img.red(160, 120), img.green(160, 120), img.blue(160, 120)]
            for (let i = 0; i < 3; ++i)
                verify(Math.abs(got[i] - data.want[i]) <= 3,
                       data.kind + " " + JSON.stringify(data.p) + ": got " + got + ", expected " + data.want)
            fill.layers = null
        }

        // the two that make a PATTERN out of a flat colour rather than a value
        function test_dither_and_scanlines_make_a_pattern() {
            fill.mask = null
            fill.layers = Theme.layersOf({ layers: ["#ff808080", ({ source: "dither", params: ({ size: 1, levels: 2 }) })] })
            let img = shot(0), lo = 255, hi = 0
            for (let y = 100; y < 140; ++y) for (let x = 140; x < 180; ++x) { lo = Math.min(lo, img.red(x, y)); hi = Math.max(hi, img.red(x, y)) }
            compare(lo, 0, "a dither of mid grey to two levels has black in it")
            compare(hi, 255, "and white")
            // and keeps the tone: over whole tiles of the matrix, as many
            // white as black for a mid grey, and a quarter white for a dark
            // one, because the thresholds are centred
            let white = 0
            for (let y = 104; y < 136; ++y) for (let x = 144; x < 176; ++x) if (img.red(x, y) > 127) ++white
            verify(Math.abs(white - 512) <= 40, "half of 1024 pixels white for mid grey: " + white)
            fill.layers = Theme.layersOf({ layers: ["#ff404040", ({ source: "dither", params: ({ size: 1, levels: 2 }) })] })
            img = shot(0); white = 0
            for (let y = 104; y < 136; ++y) for (let x = 144; x < 176; ++x) if (img.red(x, y) > 127) ++white
            verify(Math.abs(white - 256) <= 40, "a quarter white for #404040: " + white)
            // strength 0 is a posterize: no pattern at all
            fill.layers = Theme.layersOf({ layers: ["#ff808080", ({ source: "dither", params: ({ size: 1, levels: 2, strength: 0 }) })] })
            img = shot(0); lo = 255; hi = 0
            for (let y = 100; y < 140; ++y) for (let x = 140; x < 180; ++x) { lo = Math.min(lo, img.red(x, y)); hi = Math.max(hi, img.red(x, y)) }
            compare(lo, hi, "no strength, no pattern")
            fill.layers = Theme.layersOf({ layers: ["#ff808080", ({ source: "scanlines", params: ({ pitch: 4, darkness: 1 }) })] })
            img = shot(0); lo = 255; hi = 0
            for (let y = 100; y < 140; ++y) { lo = Math.min(lo, img.red(160, y)); hi = Math.max(hi, img.red(160, y)) }
            compare(lo, 0, "scanlines at full darkness go to black")
            verify(Math.abs(hi - 128) <= 2, "and leave the other rows alone: " + hi)
            fill.layers = null
        }

        // The edge in pixels: a bevel a set depth deep on a card and on a
        // window alike. Twelve pixels in from the edge is inside a 20px edge
        // and well clear of a 1px one.
        function test_a_shape_aware_edge_can_be_absolute() {
            fill.mask = null
            const at = (edge) => {
                fill.layers = Theme.layersOf({ colour: "#ff808080", source: "bevel",
                                               params: { speed: 0, scale: 1, angle: 315, own: { edge: edge, edgeAuto: 0 } } })
                const img = shot(0)
                return ({ edge: [img.red(12, 120), img.green(12, 120), img.blue(12, 120)],
                          mid: [img.red(160, 120), img.green(160, 120), img.blue(160, 120)] })
            }
            const thin = at(1), wide = at(20)
            compare(thin.mid.join(), wide.mid.join(), "the interior is the same either way")
            verify(Math.abs(thin.edge[0] - thin.mid[0]) <= 3, "12px in is flat past a 1px edge: " + thin.edge + " vs " + thin.mid)
            verify(Math.abs(wide.edge[0] - wide.mid[0]) > 6, "and shaded inside a 20px one: " + wide.edge + " vs " + wide.mid)
            // and auto scaled by a percentage: the auto edge here is 8px, so
            // 12px in is flat at 100% and shaded at 300%
            const pct = (p) => {
                fill.layers = Theme.layersOf({ colour: "#ff808080", source: "bevel",
                                               params: { speed: 0, scale: 1, angle: 315, own: { edgeAuto: 1, edgeScale: p } } })
                const img = shot(0)
                return Math.abs(img.red(12, 120) - img.red(160, 120))
            }
            verify(pct(100) <= 3, "auto at 100%: " + pct(100))
            verify(pct(300) > 6, "auto at 300%: " + pct(300))
            fill.layers = null
        }

        // How deep a contour goes: at a depth of 4 the rings stop at the
        // edge and 12px in is the flat base; at 30 they reach it.
        function test_a_contours_depth_can_be_named() {
            fill.mask = null
            const at = (depth) => {
                fill.layers = Theme.layersOf({ colour: "#ff808080", source: "contour",
                                               params: { speed: 0, scale: 1, angle: 0, own: { depth: depth, depthAuto: 0, edge: 4, edgeAuto: 0 } } })
                const img = shot(0)
                let lo = 255, hi = 0
                for (let x = 12; x < 20; ++x) { lo = Math.min(lo, img.red(x, 120)); hi = Math.max(hi, img.red(x, 120)) }
                return hi - lo
            }
            verify(at(4) <= 2, "flat past a shallow depth: " + at(4))
            verify(at(30) > 6, "rings inside a deep one: " + at(30))
            fill.layers = null
        }
        // ...and past the field's usual reach: a depth of 100 rings 60px in,
        // which a 32px field could never see, in a masked shape or a plain one
        function test_a_contour_can_reach_past_thirty_two() {
            const rings = (depth, masked) => {
                fill.mask = masked ? coverage : null
                fill.layers = Theme.layersOf({ colour: "#ff808080", source: "contour",
                                               params: { speed: 0, scale: 1, angle: 0, own: { depth: depth, depthAuto: 0, edge: 4, edgeAuto: 0 } } })
                wait(60)
                const img = shot(0)
                let lo = 255, hi = 0
                for (let x = 60; x < 72; ++x) { lo = Math.min(lo, img.red(x, 120)); hi = Math.max(hi, img.red(x, 120)) }
                return hi - lo
            }
            compare(Theme.fieldReach(fill.layers), 32)
            verify(rings(30, false) <= 2, "60px in is past a 30px depth: " + rings(30, false))
            verify(rings(100, false) > 6, "and inside a 100px one: " + rings(100, false))
            compare(Theme.fieldReach(fill.layers), 128)
            verify(rings(100, true) > 6, "through the field too: " + rings(100, true))
            // auto at 300% is 93px: the field is measured that far as well
            fill.layers = Theme.layersOf({ colour: "#ff808080", source: "contour",
                                           params: { speed: 0, own: { depthAuto: 1, depthScale: 300 } } })
            compare(Theme.fieldReach(fill.layers), 128)
            fill.mask = null
            fill.layers = null
        }

        // a filter with nothing under it is nothing: not white, not black
        function test_a_filter_at_the_bottom_draws_nothing() {
            fill.mask = null
            fill.visible = false
            const ground = shot(0)
            fill.visible = true
            fill.layers = Theme.layersOf({ layers: [({ source: "invert" }), "#ff808080"] })
            // the filter is the BOTTOM layer here; the grey covers it anyway,
            // so compare against grey alone
            const withF = shot(0)
            fill.layers = Theme.layersOf({ layers: ["#ff808080"] })
            verify(shot(0).equals(withF), "a filter under everything changes nothing")
            fill.layers = Theme.layersOf({ layers: [({ source: "invert" })] })
            verify(shot(0).equals(ground), "and alone it draws nothing at all")
            fill.layers = null
        }

        // A phase offset moves a layer even when nothing is moving. Two layers
        // of one kind draw the same picture at speed 0, which is the case the
        // offset exists for; one that only shifted the clock would do nothing
        // there.
        function test_a_phase_offset_shifts_a_still_layer_data() {
            return ["opal", "rainbow", "lava", "raster", "rim"].map(k => ({ tag: k, kind: k }))
        }
        function test_a_phase_offset_shifts_a_still_layer(data) {
            fill.mask = data.kind === "rim" ? coverage : null
            const base = ({ source: data.kind, colour: "#315080",
                            params: ({ speed: 0, scale: 1, angle: 0 }) })
            fill.layers = [base]
            const still = shot(0)
            fill.layers = [Object.assign({}, base, ({ phase: 0.37 }))]
            verify(!shot(0).equals(still), "a phase offset moves a layer at speed 0")
            fill.layers = [Object.assign({}, base, ({ phase: 0 }))]
            verify(shot(0).equals(still), "and zero is where it was")
        }

        function test_material_data() {
            return ["agate", "opal", "nebula", "mercury", "lucent", "gyroid", "kaleido", "raster", "bevel", "contour", "rim", "trace", "tidal", "cloud", "toon", "comic", "doodle", "dome"].map(kind => ({ tag: kind, kind: kind }))
        }
        function test_material(data) {
            fill.kind = data.kind
            const still = paint(0, 0)
            let low = 765, high = 0
            // Edge styles intentionally leave the interior plain. A sparse
            // interior grid can miss every thin contour, so include the rim.
            const shaped = Theme.fillShape(data.kind)
            const start = shaped ? 1 : 10, dx = shaped ? 2 : 23, dy = shaped ? 2 : 19
            for (let y = start; y < still.height; y += dy) {
                for (let x = start; x < still.width; x += dx) {
                    const light = still.red(x, y) + still.green(x, y) + still.blue(x, y)
                    low = Math.min(low, light); high = Math.max(high, light)
                }
            }
            verify(high - low > 60, "a detailed fill, not an empty shader or flat fallback")
            verify(still.equals(paint(0, 1000)), "speed zero freezes every layer")
            verify(!still.equals(paint(0.5, 4)), "the material animates")
            const reverse = paint(-0.5, 4)
            verify(reverse.equals(paint(0.5, -4)), "negative speed reverses the same animation")
            verify(!still.equals(paint(0, 0, 2)), "scale changes the pattern")
            verify(!still.equals(paint(0, 0, 1, 90)), "angle rotates the pattern")
            const red = paint(0, 0, 1, 0, ["#ff3020"])
            verify(!red.equals(paint(0, 0, 1, 0, ["#20ff70"])), "the palette is editable")
            fill.colourA = "#a04020"
            verify(!red.equals(paint(0, 0, 1, 0, ["#ff3020"])), "base tint works with a palette too")
            fill.colourA = "#315080"
            const stops = ["#000000", "#000000", "#000000", "#000000", "#000000", "#000000"]
            const dark = paint(0, 0, 1, 0, stops)
            for (let i = 0; i < stops.length; ++i) {
                const changed = stops.slice()
                changed[i] = "#ffffff"
                verify(!dark.equals(paint(0, 0, 1, 0, changed)), "palette stop " + (i + 1) + " is visible")
            }

            fill.visible = false
            const background = paint(0, 0)
            fill.visible = true
            verify(background.equals(paint(0, 0, 1, 0, ["#00ff3020"])), "stop alpha reaches the output")
            fill.mask = coverage
            const masked = paint(0, 0)
            compare(masked.pixel(240, 120), background.pixel(240, 120), "outside the glyph coverage")
            compare(masked.pixel(80, 120), still.pixel(80, 120), "inside the glyph coverage")
            fill.opacity = 0
            verify(background.equals(paint(0, 0)), "item opacity still applies to masked fills")
        }
        // A gradient that spans the item runs from its colour at the edge the
        // angle starts from to its last stop at the far edge, and a wider
        // item is the same gradient: a title bar lit from above.
        function test_a_spanning_gradient_is_the_same_at_any_width() {
            fill.kind = "gradient"
            fill.colourA = "#ff0000"
            const prm = { speed: 0, scale: 1, angle: 90, colours: ["#0000ff"], fit: 1, own: { fit: 1 } }
            fill.params = prm
            scene.width = 120
            const narrow = shot(0)
            compare(narrow.red(60, 1) > 230 && narrow.blue(60, 1) < 25, true, "top is the colour: " + narrow.pixel(60, 1))
            compare(narrow.blue(60, 238) > 230 && narrow.red(60, 238) < 25, true, "bottom is the last stop: " + narrow.pixel(60, 238))
            scene.width = 480
            const wide = shot(0)
            // x stays inside the first 320px: the runner's window keeps its
            // starting size, and on Mesa the grab beyond it is transparent
            for (const y of [1, 60, 120, 180, 238])
                verify(Math.abs(wide.red(300, y) - narrow.red(60, y)) <= 3, "row " + y + ": " + wide.pixel(300, y) + " vs " + narrow.pixel(60, y))
        }
        // Placed stops let a gradient hold then fall: an XP caption holds its
        // light for the top two fifths and drops over a ninth of its height,
        // which evenly spread stops cannot express.
        function test_a_placed_stop_holds_then_falls() {
            fill.kind = "gradient"
            fill.colourA = "#88bef3"
            function profile() {
                wait(60)
                const img = grabImage(scene)
                const x = Math.round(img.width / 2)
                const steps = []
                for (let y = 1; y < img.height; ++y)
                    steps.push(Math.abs(img.red(x, y) - img.red(x, y - 1))
                             + Math.abs(img.green(x, y) - img.green(x, y - 1)))
                return steps
            }
            const cols = ["#5f9be4", "#3579ce", "#2d55b0"]
            fill.params = ({ speed: 0, scale: 1, angle: 90, colours: cols, fit: 1 })
            const even = profile()
            fill.params = ({ speed: 0, scale: 1, angle: 90, colours: cols, fit: 1,
                             stop1: 0.385, stop2: 0.5, stop3: 1 })
            const placed = profile()
            function peak(v) { return Math.max(...v) }
            function mid(v) { const w = v.slice().sort((a, b) => a - b); return w[Math.floor(w.length / 2)] }
            // the fall is several times the ramps either side of it, and the
            // even spread has no such thing
            verify(peak(placed) >= mid(placed) * 4, "fall " + peak(placed) + " ramp " + mid(placed))
            verify(peak(even) < mid(even) * 4, "even spread should not break: " + peak(even))
            // ...and it falls where it was put
            const at = placed.indexOf(peak(placed)) / placed.length
            verify(at > 0.33 && at < 0.55, "fell at " + at.toFixed(2))
        }

        // Two stops in one place are a line, which is the thing even spacing
        // can never draw however many stops it is given.
        function test_two_stops_in_one_place_draw_a_line() {
            fill.kind = "gradient"
            fill.colourA = "#ffffff"
            fill.params = ({ speed: 0, scale: 1, angle: 90, fit: 1,
                             colours: ["#ffffff", "#000000", "#000000"],
                             stop1: 0.5, stop2: 0.5, stop3: 1 })
            wait(60)
            const img = grabImage(scene)
            const x = Math.round(img.width / 2)
            let worst = 0
            for (let y = 1; y < img.height; ++y)
                worst = Math.max(worst, Math.abs(img.red(x, y) - img.red(x, y - 1)))
            verify(worst > 200, "a step of " + worst)
        }

        // A mask's edge is as soft as the layer asks. A line is right for a
        // rim and wrong for a glow; `maskSoft` is how far the band fades, and
        // zero is a line.
        function test_a_masked_layer_fades_by_its_softness() {
            fill.kind = "colour"
            fill.colourA = "#101820"
            const rim = { colour: "#ffffff", source: "colour", mask: "edge", maskDist: 12 }
            fill.layers = [{ colour: "#101820", source: "colour" }, rim]
            const hard = shot(0)
            fill.layers = [{ colour: "#101820", source: "colour" },
                           Object.assign({}, rim, ({ maskSoft: 8 }))]
            const soft = shot(0)
            // across the band's edge, count the steps between the two colours
            function steps(img) {
                let n = 0
                for (let x = 2; x < 30; ++x) {
                    const r = img.red(x, scene.height / 2)
                    if (r > 20 && r < 245) ++n
                }
                return n
            }
            verify(steps(soft) > steps(hard) + 3,
                   "soft " + steps(soft) + " vs hard " + steps(hard))
            fill.layers = [{ colour: "#101820", source: "colour" },
                           Object.assign({}, rim, ({ maskSoft: 0 }))]
            verify(shot(0).equals(hard), "and zero is the edge it had")
        }
}
}
