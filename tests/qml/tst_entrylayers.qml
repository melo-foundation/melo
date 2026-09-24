import QtQuick
import QtTest
import "../../src/qml"

// An entry is a list of layers, most often a list of one. These are the rules a picker that edits stacks depends on: a
// legacy entry reads as a stack, a stack of one is written back flat, and a
// kind's own options survive a trip through code that has never heard of them.
Item {
    TestCase {
        name: "EntryLayers"

        function test_a_flat_entry_is_a_stack_of_one() {
            compare(Theme.layersOf("#ff0000").length, 1)
            compare(Theme.layersOf({ colour: "#ff0000", source: "opal" }).length, 1)
            compare(Theme.layersOf(null).length, 1)
            compare(Theme.layersOf({ colour: "#ff0000", source: "opal" })[0].source, "opal")
        }

        function test_a_stack_reads_bottom_up() {
            const e = { layers: [ { colour: "#112233", source: "opal" },
                                  { colour: "#445566", source: "doodle", opacity: 0.4 } ] }
            const l = Theme.layersOf(e)
            compare(l.length, 2)
            compare(l[0].source, "opal")
            compare(l[1].source, "doodle")
            compare(l[1].opacity, 0.4)
            compare(l[0].opacity, 1)          // absent means opaque
        }

        function test_an_empty_layer_list_is_still_one_layer() {
            // a file that lost its layers must draw something, not nothing
            compare(Theme.layersOf({ layers: [], colour: "#ff0000" }).length, 1)
            compare(Theme.layersOf({ layers: [null], colour: "#ff0000" }).length, 1)
        }

        function test_a_stack_of_one_is_written_flat() {
            const e = { colour: "#ff0000", source: "opal", params: { speed: 0.5 } }
            const back = Theme.entryFromLayers(Theme.layersOf(e), e)
            verify(back.layers === undefined)     // no list until there are two
            compare(back.source, "opal")
            compare(back.params.speed, 0.5)
        }

        function test_two_layers_are_written_as_a_list() {
            const e = { layers: [ { colour: "#112233", source: "opal" },
                                  { colour: "#445566", source: "doodle", opacity: 0.4 } ] }
            const back = Theme.entryFromLayers(Theme.layersOf(e), e)
            compare(back.layers.length, 2)
            compare(back.layers[1].opacity, 0.4)
            verify(back.layers[0].opacity === undefined)   // 1 is not written
        }

        // A kind may name options of its own. Code that does not know them must
        // carry them through rather than drop them, or an older melo silently
        // flattens a theme a newer one wrote.
        function test_a_kinds_own_options_survive() {
            const e = { colour: "#ff0000", source: "doodle",
                        params: { speed: 0.2, grain: 0.7, wobble: 3 } }
            const l = Theme.layersOf(e)
            compare(l[0].params.own.grain, 0.7)
            compare(l[0].params.own.wobble, 3)
            const back = Theme.entryFromLayers(l, e)
            compare(back.params.grain, 0.7)
            compare(back.params.wobble, 3)
            compare(back.params.speed, 0.2)
        }


        // A code carries the whole stack. Nobody reads it (it is what Copy and
        // Paste move), so every layer is written out in full.
        function test_a_stack_codes_and_decodes() {
            const e = { layers: [ { colour: "#112233", source: "opal", params: { speed: 0, scale: 1, angle: 0 } },
                                  { colour: "#445566", source: "gloss", params: { speed: 0, scale: 1, angle: 0 },
                                    blend: "screen", opacity: 0.4 } ] }
            const code = Theme.entryToCode(e)
            compare(code.split("+").length, 2)
            const back = Theme.codeToEntry(code)
            compare(back.layers.length, 2)
            compare(back.layers[0].source, "opal")
            compare(back.layers[1].source, "gloss")
            compare(back.layers[1].blend, "screen")
            fuzzyCompare(back.layers[1].opacity, 0.4, 0.01)
            compare(Theme.entryToCode(back), code)
        }

        // A translucent stop survives the round trip. A colour with alpha
        // prints as #aarrggbb, so its first six characters are `aarrgg`:
        // written that way, #00ffffff would come back as #00ffff, an opaque
        // cyan.
        function test_a_palette_keeps_the_alpha_of_its_stops() {
            const cols = ["#2bbd29", "#00ffffff", "#80ff0000", "#1ab919"]
            const e = { colour: "#1ab919", source: "gradient", space: "item",
                        params: { speed: 0, scale: 1, angle: 90, colours: cols, fit: 1 } }
            const back = Theme.codeToEntry(Theme.entryToCode(e))
            compare(Theme.styledOf(back).colours, cols)
            // and a palette with no alpha in it pays nothing: the section
            // costs its tag, a count and a byte a stop, and is not written at
            // all when every stop is opaque
            const mk = (c) => ({ colour: "#1ab919", source: "gradient", space: "item",
                                 params: { speed: 0, scale: 1, angle: 90, colours: c, fit: 1 } })
            const opaque = Theme.entryToCode(mk(["#2bbd29", "#1ab919"]))
            const faded  = Theme.entryToCode(mk(["#2bbd29", "#801ab919"]))
            compare(faded.length - opaque.length, 2 + 2 * 2)
        }

        // The halo is the entry's, not a layer's: written once after the
        // stack, and read back onto the entry rather than the top layer.
        function test_a_stacks_halo_belongs_to_the_entry() {
            const e = { layers: [ { colour: "#112233" }, { colour: "#445566" } ],
                        effect: { kind: "glow", size: 3, soft: 0.5, dx: 0, dy: 0, opacity: 1, colour: "#ff0000" } }
            const back = Theme.codeToEntry(Theme.entryToCode(e))
            compare(back.effect.kind, "glow")
            verify(back.layers[1].effect === undefined)
        }

        // A code from a newer melo lands as the closest thing this build can
        // say, rather than being refused whole.
        function test_an_unknown_tag_keeps_what_came_before_it() {
            compare(Theme.codeToEntry("#3060ffz99"), "#3060ff")
            const back = Theme.codeToEntry("#3060ffb1z99")
            compare(back.colour, "#3060ff"); compare(back.blend, "multiply")
            // a segment cut short is the end of what is understood, not NaN
            compare(Theme.codeToEntry("#3060ffb"), "#3060ff")
            const cut = Theme.codeToEntry("#3060ffs02")
            compare(cut, "#3060ff")
            // a malformed colour is a typo, not a version
            compare(Theme.codeToEntry("#12"), null)
        }

        // A stack reads as its bottom layer. Almost everything that reads an
        // entry takes a single value (a colour for a Text, a tint for a
        // BlendRect), and a stack has no `colour` of its own, so otherwise
        // every one of them would get the fallback.
        function test_a_stack_reads_as_its_bottom_layer() {
            const e = ({ layers: [ { colour: "#1c0e15" },
                                   { colour: "#8040c0", source: "aurora", params: { speed: 0.2 } } ] })
            compare(Theme.colorOf(e, "#ffffff").toString(), "#1c0e15")
            compare(Theme.sourceOf(e), "colour")
            compare(Theme.styledOf(e).speed, Theme.styledOf(null).speed, "the levers are the bottom layer's")
            // and what CAN draw the whole thing is told there is one to draw
            verify(Theme.anyStyled(e), "a fill above a plain colour is still a fill")
            verify(!Theme.hasAdaptive(e))
            verify(Theme.hasAdaptive({ layers: [{ colour: "#1c0e15" }, { source: "adaptive" }] }))
        }

        // Array-like, not an array. Every entry that has been through the
        // settings store comes back with its layers as a QVariantList, which
        // indexes and has a length and fails Array.isArray; it must still read
        // as a stack.
        function test_a_stack_from_the_store_is_still_a_stack() {
            const fromCpp = ({ 0: { colour: "#1c0e15" },
                               1: { colour: "#8040c0", source: "aurora", params: { speed: 0.2 } },
                               length: 2 })
            const e = ({ layers: fromCpp })
            compare(Theme.layersOf(e).length, 2)
            compare(Theme.colorOf(e, "#ffffff").toString(), "#1c0e15")
            compare(Theme.sourceOf(Theme.layersOf(e)[1]), "aurora")
            verify(Theme.anyStyled(e))
            // and a colour the store put on the entry does not win over them
            compare(Theme.colorOf({ colour: "#ffffff", layers: fromCpp }, "#000000").toString(), "#1c0e15")
        }

        // A plain colour is a string, in a stack as everywhere else, and a
        // string layer is a layer: a flat colour laid over a fill is drawn.
        function test_a_bare_colour_is_a_layer() {
            const over  = ({ layers: [{ colour: "#ff0000", source: "opal" }, "#000000"] })
            const under = ({ layers: ["#000000", { colour: "#ff0000", source: "opal" }] })
            compare(Theme.layersOf(over).length, 2)
            compare(Theme.layersOf(under).length, 2)
            compare(Theme.sourceOf(Theme.layersOf(over)[1]), "colour")
            compare(Theme.colorOf(Theme.layersOf(over)[1], "#ffffff").toString(), "#000000")
            compare(Theme.colorOf(under, "#ffffff").toString(), "#000000", "and it is the bottom layer")
            compare(Theme.colorOf(over, "#ffffff").toString(), "#ff0000")
            // a stack of nothing but plain colours is still a stack
            compare(Theme.layersOf({ layers: ["#ff0000", "#0000ff"] }).length, 2)
        }

        // What needs the layer renderer. A fill does; so does a stack of plain
        // colours, because the flat rectangle a surface falls back to can
        // paint one colour and a stack of two is not one colour.
        function test_a_stack_of_colours_needs_the_renderer() {
            verify(!Theme.layered("#ff0000"))
            verify(!Theme.layered({ colour: "#ff0000" }))
            verify(Theme.layered({ colour: "#ff0000", source: "opal" }))
            verify(Theme.layered({ layers: ["#ff0000", "#0000ff"] }), "two colours are not one colour")
            verify(Theme.layered({ layers: ["#ff0000", { colour: "#0000ff", source: "opal" }] }))
        }

        // What a stack costs, and one definition of it: the renderer decides
        // whether to chain from the same function the picker shows a number
        // from, so the two cannot drift.
        function test_the_cost_of_a_stack_is_visible() {
            compare(Theme.stackPasses("#ff0000"), 1)
            compare(Theme.stackPasses({ layers: ["#ff0000", "#0000ff"] }), 2, "a draw a layer")
            compare(Theme.stackPasses({ layers: ["#ff0000", ({ colour: "#0000ff", blend: "screen" })] }),
                    2, "a blend factor is free")
            compare(Theme.stackPasses({ layers: ["#ff0000", ({ colour: "#0000ff", blend: "overlay" })] }),
                    4, "a target a layer, a rung for all but the bottom one, and a draw")
            compare(Theme.stackPasses({ layers: ["#ff0000", ({ colour: "#0000ff", blend: "darken" })] }),
                    4, "darken is a Min blend and refuses a texture, so it chains too")
            // ...and the bottom layer keeps its rung when only a rung can
            // apply its own alpha
            compare(Theme.stackPasses({ layers: [({ colour: "#80ff0000" }),
                                                 ({ colour: "#0000ff", blend: "overlay" })] }), 5)
            verify(!Theme.stackChains(Theme.layersOf({ layers: ["#ff0000", "#0000ff"] })))
            verify(Theme.stackChains(Theme.layersOf(
                { layers: ["#ff0000", ({ colour: "#0000ff", blend: "hue" })] })))
        }

        // Does any layer move? sourceOf and styledOf answer for the bottom
        // layer, which is right for everything that takes one value and wrong
        // for the question that starts the clock: a still colour under a
        // moving fill is a moving entry.
        function test_a_moving_layer_makes_the_entry_move() {
            verify(!Theme.entryMoves("#ff0000"))
            verify(!Theme.entryMoves({ colour: "#ff0000", source: "opal", params: { speed: 0 } }))
            verify(Theme.entryMoves({ colour: "#ff0000", source: "opal", params: { speed: 0.3 } }))
            verify(Theme.entryMoves({ layers: ["#1c0e15",
                                               { colour: "#ff0000", source: "opal", params: { speed: 0.3 } }] }),
                   "a still colour under a moving fill is a moving entry")
            verify(!Theme.entryMoves({ layers: ["#1c0e15",
                                                { colour: "#ff0000", source: "opal", params: { speed: 0 } }] }))
            // and a layer that is not a fill at all never moves
            verify(!Theme.entryMoves({ layers: ["#1c0e15", "#ff0000"] }))
        }

        // ...and the gate it feeds: with anyAnimated false the driver does not
        // run, so every moving fill in the app sits frozen until something
        // else asks for the clock.
        function test_the_clock_runs_for_a_moving_upper_layer() {
            const moving = ({ layers: ["#1c0e15",
                                       ({ colour: "#ff0000", source: "opal", params: ({ speed: 0.3 }) })] })
            Theme.p.window = moving
            Theme.pChanged()
            verify(Theme.anyAnimated, "the driver has to run or the stack is frozen")
            Theme.p.window = ({ layers: ["#1c0e15",
                                         ({ colour: "#ff0000", source: "opal", params: ({ speed: 0 }) })] })
            Theme.pChanged()
            verify(!Theme.anyAnimated, "and stop again when nothing moves")
            delete Theme.p.window
            Theme.pChanged()
        }

        // a resize pauses the clock and lets it go on; stopping it would
        // restart the driver and jump every fill back to its first frame
        function test_a_hold_pauses_the_clock_rather_than_restarting_it() {
            Theme.p.window = ({ colour: "#ff0000", source: "opal", params: ({ speed: 0.3 }) })
            Theme.pChanged()
            Theme.held = false
            wait(120)
            const t0 = Theme.clock
            verify(t0 > 0, "running: " + t0)
            Theme.held = true
            const t1 = Theme.clock; wait(120)
            fuzzyCompare(Theme.clock, t1, 0.001, "held: the clock stands")
            Theme.held = false
            wait(120)
            verify(Theme.clock > t1 + 0.05, "let go: it goes on from where it stood, " + t1 + " -> " + Theme.clock)
            verify(Theme.clock < t1 + 1, "not from nought")
            Theme.held = true
            delete Theme.p.window
            Theme.pChanged()
        }

        // Every role hands the stack to what can draw one, beside the bottom
        // layer it hands to everything else.
        function test_a_role_carries_its_stack() {
            const r = Theme.role("accent"), ink = Theme.inkRole("text")
            verify(Array.isArray(r.layers) && r.layers.length >= 1)
            verify(Array.isArray(ink.layers) && ink.layers.length >= 1)
        }

        function test_a_reported_stack_code_round_trips() {
            const back = Theme.codeToEntry("#9a4b2949s0c802000+#653862s11791a7b6514a1d00c92451c92487c92493522f000000")
            compare(back.layers.length, 2)
            compare(Theme.sourceOf(back.layers[0]), "brushed")
            compare(Theme.sourceOf(back.layers[1]), "mercury")
            fuzzyCompare(Theme.colorOf(back.layers[0], "#000000").a, 0.604, 0.01)
            const st = Theme.styledOf(back.layers[1])
            compare(st.colours.length, 6, JSON.stringify(st.colours))
            compare(st.colours[5], "#000000", "six stops, and the last is black rather than an added white")
            fuzzyCompare(st.speed, -0.05, 0.01)
            fuzzyCompare(st.scale, 0.82, 0.01)
            compare(st.angle, 174)
        }

        function test_the_common_levers_are_not_treated_as_own() {
            const p = Theme.layersOf({ params: { speed: 1, scale: 2, angle: 90, colours: ["#fff"] } })[0].params
            compare(Object.keys(p.own).length, 0)
        }

        // A filter is a layer with no fill of its own: it changes what is
        // under it. It is a source like any other to the readers, it needs
        // the renderer, and it always chains, since a blend factor cannot read
        // the layers below.
        function test_a_filter_is_a_source_that_needs_the_renderer() {
            verify(Theme.isFilter("pixelate"))
            verify(!Theme.isFilter("opal"))
            verify(!Theme.isStyled("pixelate"), "a filter is not a fill")
            compare(Theme.sourceOf({ source: "pixelate" }), "pixelate")
            compare(Theme.sourceName("grey"), "greyscale")
            compare(Theme.filterIndex("pixelate"), 1, "1-based: 0 is no filter")
            compare(Theme.filterIndex("opal"), 0)
            const e = { layers: ["#ff0000", ({ source: "pixelate" })] }
            verify(Theme.anyFilter(e))
            verify(!Theme.anyStyled(e))
            verify(Theme.layered(e))
            verify(Theme.stackChains(Theme.layersOf(e)))
            compare(Theme.stackPasses(e), 3, "a target for the fill, a rung above the bottom, and a draw")
            compare(Theme.stackPasses({ layers: ["#ff0000", "#00ff00", ({ source: "pixelate" })] }), 5)
        }

        function test_a_filter_codes_as_its_kind_and_options() {
            const e = { layers: [ { colour: "#112233" },
                                  { source: "pixelate", params: { own: { size: 16 } }, opacity: 0.5 } ] }
            const code = Theme.entryToCode(e)
            verify(code.split("+")[1].indexOf("f01k13a") > 0, "a filter by its place, then its options, no levers: " + code)
            const back = Theme.codeToEntry(code)
            compare(back.layers.length, 2)
            compare(back.layers[1].source, "pixelate")
            compare(Number(Theme.styledOf(back.layers[1]).own.size), 16)
            fuzzyCompare(back.layers[1].opacity, 0.5, 0.01)
            compare(Theme.entryToCode(back), code)
            // a filter this build does not know reads as nothing, and the
            // layer under it is untouched
            const unknown = Theme.codeToEntry(code.split("+")[0] + "+#fffffff63")
            compare(Theme.colorOf(unknown.layers ? unknown.layers[0] : unknown, "#000000").toString(), "#112233")
        }

        function test_a_fills_options_ride_after_its_levers() {
            const e = { colour: "#112233", source: "toon",
                        params: { speed: 0, scale: 1, angle: 0, own: { ink: 2.6, relief: 0.32 } } }
            const back = Theme.codeToEntry(Theme.entryToCode(e))
            fuzzyCompare(Number(Theme.styledOf(back).own.ink), 2.6, 0.05)
            fuzzyCompare(Number(Theme.styledOf(back).own.relief), 0.32, 0.02)
        }
    }
}
