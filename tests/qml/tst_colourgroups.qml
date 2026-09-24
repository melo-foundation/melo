import QtQuick
import QtTest
import "../../src/qml"

// The palette as colours rather than roles. colourGroups walks the shapes a
// v3 palette actually holds — a plain string, an object, a stack of layers, a
// fill's palette stops, an ink's halo — and recolour writes back into exactly
// the slots it named. Both are pure, so the palette is handed in.
Item {
    readonly property var pal: ({
        window: "#101010",
        chrome: { colour: "#101010", blend: "multiply" },
        // a stack: two layers, the upper one a fill with stops
        player: { layers: [ { colour: "#101010" },
                            { colour: "#3060ff", source: "aurora",
                              params: { speed: 0.2, colours: ["#101010", "#3060ff", "#ff0000"] } } ] },
        // a bare string inside a stack is a layer too
        panel: { layers: [ "#3060ff", { colour: "#ff0000", source: "gradient" } ] },
        // an ink, with a halo colour of its own
        text: { colour: "#ffffff", effect: { kind: "glow", colour: "#3060ff" } },
        // not literals: a sentinel is left where it is
        accent: "systemaccent",
        border: "system:window"
    })

    TestCase {
        name: "ColourGroups"

        function groupOf(gs, hex) {
            for (let i = 0; i < gs.length; ++i) if (gs[i].colour === hex) return gs[i]
            return null
        }
        function pathOf(g, role) {
            for (let i = 0; i < g.places.length; ++i)
                if (g.places[i].role === role) return JSON.stringify(g.places[i].path)
            return ""
        }

        // #101010 is in four places: two whole entries, one layer, one stop.
        // Ordered by count, so the commonest colour is the first row.
        function test_every_place_is_found_and_counted() {
            const gs = Theme.colourGroups(pal)
            const g = gs[0]
            compare(g.colour, "#101010")
            compare(g.count, 4)
            compare(pathOf(g, "window"), "[]")                      // a plain string entry
            compare(pathOf(g, "chrome"), "[\"colour\"]")            // an object's colour
            compare(pathOf(g, "player"), "[\"layers\",0,\"colour\"]")
            // the stop is the player's second place
            let stop = ""
            for (let i = 0; i < g.places.length; ++i)
                if (g.places[i].role === "player" && g.places[i].path.length === 5) stop = JSON.stringify(g.places[i].path)
            compare(stop, "[\"layers\",1,\"params\",\"colours\",0]")
        }

        function test_a_stop_an_effect_and_a_bare_layer() {
            const g = Theme.colourGroups(pal)[1]
            compare(g.colour, "#3060ff")
            compare(g.count, 4)   // the layer, its stop, the bare layer, the halo
            compare(pathOf(g, "panel"), "[\"layers\",0]")           // a bare string layer
            compare(pathOf(g, "text"), "[\"effect\",\"colour\"]")
            const red = groupOf(Theme.colourGroups(pal), "#ff0000")
            compare(red.count, 2)
        }

        function test_a_sentinel_is_not_a_colour() {
            const gs = Theme.colourGroups(pal)
            for (let i = 0; i < gs.length; ++i)
                verify(gs[i].colour.indexOf("system") < 0)
            compare(groupOf(gs, "#ffffff").count, 1)
        }

        // near-equals fold into the commonest of them; the group's colour is
        // that one, not an average
        function test_near_equal_colours_fold_into_the_most_used() {
            const near = ({ a: "#303030", b: "#303030", c: "#303032", d: "#404040" })
            const gs = Theme.colourGroups(near)
            compare(gs.length, 2)
            compare(gs[0].colour, "#303030")
            compare(gs[0].count, 3)
            compare(gs[1].colour, "#404040")
            // tolerance 0 keeps every value apart
            compare(Theme.colourGroups(near, 0).length, 3)
        }

        // alpha is a colour doing another job: never folded, in Qt's own
        // #AARRGGBB, the order the code and the palette use
        function test_alpha_is_kept_apart() {
            const gs = Theme.colourGroups({ a: "#3060ff", b: "#803060ff", c: "#803060ff" })
            compare(gs.length, 2)
            compare(gs[0].colour, "#803060ff")
            compare(gs[0].count, 2)
            compare(gs[1].colour, "#3060ff")
        }

        // what comes back replaces every occurrence in every place, and
        // nothing else moves
        function test_recolour_writes_every_place() {
            const gs = Theme.colourGroups(pal)
            const out = Theme.recolour(pal, groupOf(gs, "#101010"), "#00ff00")
            compare(out.window, "#00ff00")
            compare(out.chrome.colour, "#00ff00")
            compare(out.chrome.blend, "multiply")              // other fields kept
            compare(out.player.layers[0].colour, "#00ff00")
            compare(out.player.layers[1].params.colours[0], "#00ff00")
            compare(out.player.layers[1].colour, "#3060ff")    // untouched
            compare(out.player.layers[1].source, "aurora")
            compare(out.text.colour, "#ffffff")
            compare(pal.window, "#101010")                     // the original is not written
            compare(Theme.colourGroups(out)[0].colour, "#00ff00")
        }

        function test_recolour_reaches_a_bare_layer_and_a_halo() {
            const gs = Theme.colourGroups(pal)
            const out = Theme.recolour(pal, groupOf(gs, "#3060ff"), "#800000ff")
            compare(out.panel.layers[0], "#800000ff")          // Qt's order in, Qt's order out
            compare(out.text.effect.colour, "#800000ff")
            compare(out.text.effect.kind, "glow")
            const g = groupOf(Theme.colourGroups(out), "#800000ff")
            compare(g.count, 4)
        }

        // a stamp says which swatch a role took its value from; a recolour is
        // not the swatch changing, so the stamp stays what it was
        function test_a_stamp_is_left_alone() {
            const st = ({ card: { colour: "#101010", from: "s1" } })
            const out = Theme.recolour(st, Theme.colourGroups(st)[0], "#00ff00")
            compare(out.card.colour, "#00ff00")
            compare(out.card.from, "s1")
        }
    }
}
