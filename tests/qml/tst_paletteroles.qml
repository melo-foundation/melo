import QtQuick
import QtTest
import "../../src/qml"

// roleFrom (pure: palette, opacity map and scale in) on each shape a v3 palette
// holds: a colour string, a surface object, nothing. Easy to get backwards:
// floating surfaces ignore the master.
Item {
    readonly property var pal: ({
        window: "#0f0f0f",
        chrome: { colour: "#151515", blend: "multiply" },
        panel: { colour: "#123456", source: "adaptive",
                 amounts: { hue: 0.5, lum: -1, sat: 0.2, opacity: 0.9 } },
        card: "#1a1a1a"
    })
    readonly property var op: ({ window: 1, chrome: 0.7, panel: 0.9, card: 0.65, menu: 0.75 })

    TestCase {
        name: "PaletteRoles"

        function test_a_string_is_a_colour_and_nothing_else() {
            const r = Theme.roleFrom(pal, op, 1, "window")
            compare(r.colour.toString(), "#0f0f0f")
            compare(r.source, "colour")
            compare(r.blend, "")
            fuzzyCompare(r.opacity, 1, 0.001)
        }

        function test_an_object_carries_blend_and_source() {
            const c = Theme.roleFrom(pal, op, 1, "chrome")
            compare(c.colour.toString(), "#151515")
            compare(c.blend, "multiply")
            compare(c.source, "colour")
            const p = Theme.roleFrom(pal, op, 1, "panel")
            compare(p.source, "adaptive")
            fuzzyCompare(p.amounts.x, 0.5, 0.001)
            fuzzyCompare(p.amounts.y, -1, 0.001)
            fuzzyCompare(p.amounts.w, 0.9, 0.001)
        }

        // a styled source is its kind, with its levers defaulted and clamped;
        // anything not a kind is a colour
        function test_a_styled_source_carries_its_params() {
            const sp = ({ card: { colour: "#ff0000", source: "lava",
                                  params: { speed: 4, scale: 0.01, angle: 45, colour2: "#00ff00" } },
                          button: { colour: "#ffffff", source: "rainbow" },
                          hover: { colour: "#ffffff", source: "sparkle" } })
            const c = Theme.roleFrom(sp, op, 1, "card")
            compare(c.source, "lava")
            fuzzyCompare(c.params.speed, 1, 0.001)
            fuzzyCompare(c.params.scale, 0.1, 0.001)
            fuzzyCompare(c.params.angle, 45, 0.001)
            compare(c.params.colours[0], "#00ff00")   // colour2 reads as the first stop
            const f = Theme.roleFrom(sp, op, 1, "button")
            compare(f.source, "rainbow")
            fuzzyCompare(f.params.speed, Theme.styledDefaults.speed, 0.001)
            compare(Theme.roleFrom(sp, op, 1, "hover").source, "colour")
        }

        // a code round-trips an entry to within a byte, and a bare colour
        // stays a string
        function test_an_entry_codes_and_decodes() {
            compare(Theme.codeToEntry("#3060ff"), "#3060ff")
            const e = ({ colour: "#3060ff", source: "rainbow", params: { speed: 0.3, scale: 1, angle: 20 },
                         blend: "multiply", effect: { kind: "outline", size: 2, soft: 0, dx: 0, dy: 1,
                                                      colour: { source: "adaptive", amounts: { hue: 0, lum: -1, sat: 0, opacity: 1 } },
                                                      opacity: 0.75 } })
            const code = Theme.entryToCode(e)
            verify(code.startsWith("#3060ffs02"), code)
            const back = Theme.codeToEntry(code)
            compare(back.source, "rainbow"); compare(back.blend, "multiply")
            fuzzyCompare(back.params.speed, 0.3, 0.01); fuzzyCompare(back.params.scale, 1, 0.04); compare(back.params.angle, 20)
            compare(back.effect.kind, "outline"); fuzzyCompare(back.effect.size, 2, 0.05); fuzzyCompare(back.effect.opacity, 0.75, 0.01)
            compare(Theme.sourceOf(back.effect.colour), "adaptive"); fuzzyCompare(Theme.adaptiveOf(back.effect.colour).y, -1, 0.01)
            compare(Theme.entryToCode(back), code)
            const two = Theme.codeToEntry(Theme.entryToCode({ colour: "#8a1e1e", source: "lava", params: { colours: ["#ffd25a", "#ff30a0"] } }))
            compare(two.source, "lava"); compare(two.params.colours.length, 2); compare(two.params.colours[1], "#ff30a0")
            // a theme written with colour2 reads as a one-stop palette
            compare(Theme.styledOf({ source: "lava", params: { colour2: "#ffd25a" } }).colours[0], "#ffd25a")
            compare(Theme.codeToEntry("#12"), null); compare(Theme.codeToEntry("nope"), null)
        }
        function test_builtin_fill_codes_are_append_only() {
            // The index is both the shader branch and the saved hex-code ID.
            const kinds = ["gradient", "rainbow", "prism", "foil", "lava", "plasma", "metal", "fire", "aurora",
                           "image", "gloss", "brushed", "aero", "agate", "opal", "nebula", "mercury", "lucent", "gyroid", "kaleido", "raster", "bevel", "contour", "rim", "trace", "tidal", "cloud", "toon", "comic", "doodle"]
            for (let i = 0; i < kinds.length; ++i) {
                compare(Theme.fillIndex(kinds[i]), i + 1, kinds[i])
                verify(Theme.isStyled(kinds[i]), kinds[i])
            }
        }

        function test_retired_materials_use_their_replacements() {
            compare(Theme.sourceOf({ source: "caustics" }), "agate")
            compare(Theme.sourceOf({ source: "silk" }), "mercury")
            verify(!Theme.styledKinds.includes("caustics"))
            verify(!Theme.styledKinds.includes("silk"))
            compare(Theme.codeToEntry("#315080s0e8020000").source, "agate")
            compare(Theme.codeToEntry("#315080s118020000").source, "mercury")
        }

        function test_new_materials_data() {
            return ["agate", "opal", "nebula", "mercury", "lucent", "gyroid", "kaleido", "raster", "bevel", "contour", "rim", "trace", "tidal", "cloud", "toon", "comic", "doodle"].map(kind => ({ tag: kind, kind: kind }))
        }
        function test_new_materials(data) {
            verify(Theme.fillBase(data.kind))
            verify(Theme.fillPalette(data.kind))
            compare(Theme.fillShape(data.kind), ["bevel", "contour", "rim", "trace", "tidal", "toon", "doodle"].includes(data.kind))
            compare(Theme.sourceName(data.kind), data.kind)
            const stops = ["#14345a", "#277b8a", "#7dc4af", "#cbbc85", "#de799e", "#a3abff"]
            for (const count of [0, 1, 6]) {
                const entry = ({ colour: "#324567", source: data.kind, blend: "screen",
                                 params: { speed: -0.4, scale: 2.5, angle: 135, colours: stops.slice(0, count) } })
                const surface = Theme.roleFrom(({ card: entry }), ({}), 1, "card")
                const ink = Theme.inkFrom(({ text: entry }), ({}), "text")
                compare(surface.source, data.kind)
                compare(ink.source, data.kind)
                compare(surface.params.colours, stops.slice(0, count))
                compare(ink.params.colours, stops.slice(0, count))
                const code = Theme.entryToCode(entry)
                verify(code.startsWith("#324567s" + Theme.hex2(Theme.fillIndex(data.kind))), code)
                const back = Theme.codeToEntry(code)
                compare(back.source, data.kind)
                compare(back.blend, "screen")
                compare(back.params.colours, stops.slice(0, count))
                fuzzyCompare(back.params.speed, -0.4, 0.01)
                fuzzyCompare(back.params.scale, 2.5, 0.04)
                fuzzyCompare(back.params.angle, 135, 1)
                compare(Theme.entryToCode(back), code)
                const halo = ({ colour: "#ffffff", effect: { kind: "glow", colour: entry } })
                const haloBack = Theme.codeToEntry(Theme.entryToCode(halo))
                compare(haloBack.effect.colour.source, data.kind)
                compare(haloBack.effect.colour.params.colours, stops.slice(0, count))
            }
            // Theme JSON (unlike the compact RGB code) retains stop alpha.
            const translucent = Theme.styledOf({ source: data.kind, params: { speed: 0, colours: ["#40336699"] } })
            compare(translucent.speed, 0)
            compare(translucent.colours[0], "#40336699")
        }

        function test_every_swap_rests_at_zero() {
            // a table invites a residual offset or scale at rest; none allowed
            for (const swap of ["rise", "drop", "slide", "zoom", "fade", "none"])
                for (const arriving of [true, false])
                    for (const toCentre of [true, false]) {
                        const g = Theme.swapGeometry(swap, arriving, toCentre, 1)
                        compare(g.x, 0, swap); compare(g.y, 0, swap); compare(g.s, 1, swap)
                    }
            // and away from rest the arriving and the leaving go opposite ways
            const a = Theme.swapGeometry("rise", true, true, 0), l = Theme.swapGeometry("rise", false, true, 0)
            verify(a.y > 0 && l.y < 0)
            const z = Theme.swapGeometry("zoom", true, true, 0)
            verify(z.s > 1)
        }
        function test_a_halo_in_a_fill_survives_the_code() {
            // an effect whose colour is itself a fill: the entry's grammar
            // again, after the effect bytes
            const e = ({ colour: "#ffffff", effect: { kind: "outline", size: 1.5, soft: 0, dx: 0, dy: 1, opacity: 0.75,
                         colour: { colour: "#000000", source: "lava", params: { speed: 0.3, scale: 1, angle: 0,
                                   colours: ["#ffd25a", "#ff30a0"] } } } })
            const back = Theme.codeToEntry(Theme.entryToCode(e))
            compare(back.effect.kind, "outline")
            compare(back.effect.colour.source, "lava")
            compare(back.effect.colour.params.colours.length, 2)
            compare(back.effect.colour.params.colours[1], "#ff30a0")
            compare(Theme.entryToCode(back), Theme.entryToCode(e))
            // a flat halo colour stays a string
            const flat = Theme.codeToEntry(Theme.entryToCode({ colour: "#ffffff",
                effect: { kind: "glow", size: 2, soft: 0.5, dx: 0, dy: 0, opacity: 1, colour: "#ff0000" } }))
            compare(flat.effect.colour, "#ff0000")
        }

        // A role's own opacity is absolute, so a solid header can sit under a
        // glass master; the master is what a role without one gets. It never
        // reaches a floating role: a see-through theme must not put the view's
        // own text through the panel covering it.
        function test_the_master_skips_floating_roles() {
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "window").opacity, 1, 0.001)     // its own: 1, whatever the master
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "button").opacity, 0.5, 0.001)   // no own value: the master
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "chrome").opacity, 0.7, 0.001)   // its own, untouched
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "card").opacity, 0.65, 0.001)
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "panel").opacity, 0.9, 0.001)
            fuzzyCompare(Theme.roleFrom(pal, ({}), 0.5, "panel").opacity, 1, 0.001)    // floating, no own: not the master
            fuzzyCompare(Theme.roleFrom(pal, op, 0.5, "menu").opacity, 0.75, 0.001)
        }

        // The page is nothing until set. It lies over the window, so a
        // default that followed the window would paint a glass theme twice.
        function test_the_page_is_transparent_unless_a_theme_sets_it() {
            compare(Theme.roleFrom(pal, op, 1, "page").colour.a, 0)
            const withPage = Object.assign({}, pal, { page: "#c0c0c0" })
            compare(Theme.roleFrom(withPage, op, 1, "page").colour.toString(), "#c0c0c0")
            fuzzyCompare(Theme.roleFrom(withPage, op, 0.5, "page").opacity, 0.5, 0.001, "a surface: the master")
            verify(Theme.surfaceRoles.indexOf("page") > 0)
        }

        // A layer's own opacity is in the flat colour: what a plain surface,
        // a Text or a glyph draws. The layer renderer reads the layer itself.
        function test_a_layers_opacity_reaches_the_flat_colour() {
            const p2 = Object.assign({}, pal, { card: ({ colour: "#ff8040", opacity: 0.5 }),
                                                 text: ({ colour: "#e0e0e0", opacity: 0.25 }) })
            fuzzyCompare(Theme.roleFrom(p2, op, 1, "card").colour.a, 0.5, 0.01)
            compare(Theme.roleFrom(p2, op, 1, "card").colour.toString().slice(3), "ff8040")
            fuzzyCompare(Theme.inkFrom(p2, ({}), "text").colour.a, 0.25, 0.01)
            // a stack's bottom layer, likewise; a layer that says nothing is opaque
            fuzzyCompare(Theme.roleFrom(({ card: ({ layers: [({ colour: "#ff8040", opacity: 0.5 }), "#000000"] }) }), op, 1, "card").colour.a, 0.5, 0.01)
            fuzzyCompare(Theme.roleFrom(pal, op, 1, "card").colour.a, 1, 0.001)
        }

        // An inset is four numbers a structure: a default unless the theme
        // says otherwise, one number for all four or a side
        function test_an_inset_is_the_default_until_named() {
            Theme.held = true
            delete Theme.ts.insets; Theme.tsChanged()
            compare(Theme.insetOf("page", "left"), 10)
            compare(Theme.insetOf("header", "top"), 5)
            compare(Theme.insetOf("nothing", "left"), 0)
            Theme.ts.insets = ({ page: 4, header: { top: 1 } }); Theme.tsChanged()
            compare(Theme.insetOf("page", "left"), 4); compare(Theme.insetOf("page", "bottom"), 4)
            compare(Theme.insetOf("header", "top"), 1); compare(Theme.insetOf("header", "left"), 10, "a side not named keeps the default")
            Theme.ts.uiScale = 2; Theme.tsChanged()
            compare(Theme.inset("page", "left"), 8, "pixels of the interface size")
            delete Theme.ts.insets; delete Theme.ts.uiScale; Theme.tsChanged()
        }

        // An input is a button unless a theme says otherwise, and a dropdown
        // is a button unless the theme draws it as an input
        function test_an_input_follows_the_button_unless_set() {
            compare(Theme.roleFrom(pal, op, 1, "input").colour.toString(), Theme.roleFrom(pal, op, 1, "button").colour.toString())
            compare(Theme.roleFrom(pal, op, 1, "buttonHover").colour.toString(), Theme.roleFrom(pal, op, 1, "hover").colour.toString())
            const p2 = Object.assign({}, pal, { input: "#123456" })
            compare(Theme.roleFrom(p2, op, 1, "input").colour.toString(), "#123456")
            compare(Theme.faceOf("button", false), "button"); compare(Theme.faceOf("button", true), "buttonHover")
            compare(Theme.faceOf("select", false), "button"); compare(Theme.faceOf("chip", true), "buttonHover")
            Theme.ts.inputSelects = true; Theme.tsChanged()
            compare(Theme.faceOf("select", false), "input")
            delete Theme.ts.inputSelects; Theme.tsChanged()
        }

        // A held button has a face of its own, and only when a theme asks
        // for one: `none` leaves press looking like rest.
        function test_the_press_face_follows_hover_and_only_shows_when_asked() {
            compare(Theme.roleFrom(pal, op, 1, "buttonPress").colour.toString(),
                    Theme.roleFrom(pal, op, 1, "hover").colour.toString())
            const p2 = Object.assign({}, pal, { buttonPress: "#654321" })
            compare(Theme.roleFrom(p2, op, 1, "buttonPress").colour.toString(), "#654321")
            delete Theme.ts.buttonPress; Theme.tsChanged()
            compare(Theme.faceOf("button", false, true), "button", "none presses nothing")
            compare(Theme.pressShift(true), 0)
            Theme.ts.buttonPress = "face"; Theme.tsChanged()
            compare(Theme.faceOf("button", false, true), "buttonPress")
            compare(Theme.faceOf("button", true, true), "buttonPress", "hovered and held is still held")
            compare(Theme.faceOf("button", true, false), "buttonHover")
            compare(Theme.pressShift(true), 0, "face moves nothing")
            Theme.ts.buttonPress = "sink"; Theme.tsChanged()
            compare(Theme.faceOf("button", false, true), "buttonPress")
            compare(Theme.pressShift(true), 1); compare(Theme.pressShift(false), 0)
            // a dropdown drawn as an input is a field, and a field does not sink
            Theme.ts.inputSelects = true; Theme.tsChanged()
            compare(Theme.faceOf("select", false, true), "input")
            delete Theme.ts.inputSelects; delete Theme.ts.buttonPress; Theme.tsChanged()
        }

        // Every part of a control follows something, so a theme that names
        // none of these roles still draws them: the track and the toggle's off face are the button, the fill
        // and the on face are the accent, an active button is the selected
        // surface. The two knobs follow nothing and are white.
        function test_a_controls_parts_follow_the_control_data() {
            return [{ tag: "sliderTrack", key: "sliderTrack", parent: "button" },
                    { tag: "toggleOff", key: "toggleOff", parent: "button" },
                    { tag: "sliderFill", key: "sliderFill", parent: "accent" },
                    { tag: "toggleOn", key: "toggleOn", parent: "accent" },
                    { tag: "buttonActive", key: "buttonActive", parent: "selected" },
                    { tag: "cardSelected", key: "cardSelected", parent: "selected" },
                    { tag: "scrubberTrack", key: "scrubberTrack", parent: "button" }]
        }
        function test_a_controls_parts_follow_the_control(data) {
            const p2 = Object.assign({}, pal, { button: "#222222", accent: "#cc3333",
                                                selected: "#333333", hover: "#444444" })
            const r = Theme.roleFrom(p2, op, 1, data.key), pr = Theme.roleFrom(p2, op, 1, data.parent)
            compare(r.colour.toString(), pr.colour.toString())
            // the parent's OWN opacity comes with the entry, or a track that
            // followed the button would draw solid where the button was 65%
            fuzzyCompare(r.opacity, pr.opacity, 0.001)
            const own = Object.assign({}, p2); own[data.key] = "#00ff88"
            compare(Theme.roleFrom(own, op, 1, data.key).colour.toString(), "#00ff88")
            compare(Theme.entryParents[data.key], data.parent)
        }
        function test_a_knob_is_white_until_a_theme_names_it() {
            for (const k of ["sliderKnob", "toggleKnob", "scrubberKnob"]) {
                compare(Theme.roleFrom(pal, op, 1, k).colour.toString(), "#ffffff", k)
                const p2 = Object.assign({}, pal); p2[k] = "#112233"
                compare(Theme.roleFrom(p2, op, 1, k).colour.toString(), "#112233", k)
            }
        }

        // A button that is on has a face of its own, and the pointer does not
        // change it: hover says "this is what you would pick", and it is
        // already picked. Held still wins: press is what the hand is doing now.
        function test_an_active_button_takes_the_active_face() {
            compare(Theme.faceOf("button", false, false, true), "buttonActive")
            compare(Theme.faceOf("button", true, false, true), "buttonActive", "on does not hover")
            compare(Theme.faceOf("button", false, false, false), "button")
            compare(Theme.faceOf("button", true, false), "buttonHover", "no fourth argument is not active")
            Theme.ts.buttonPress = "face"; Theme.tsChanged()
            compare(Theme.faceOf("button", true, true, true), "buttonPress")
            delete Theme.ts.buttonPress; Theme.tsChanged()
            compare(Theme.faceOf("button", true, true, true), "buttonActive", "none presses nothing")
        }

        // The primary one keeps its colour while held: only the hover moves it.
        function test_the_accent_face_ignores_the_press() {
            compare(Theme.faceOf("accent", false, false), "accent")
            compare(Theme.faceOf("accent", true, false), "accentHover")
            Theme.ts.buttonPress = "face"; Theme.tsChanged()
            compare(Theme.faceOf("accent", true, true), "accentHover", "held stays accent")
            compare(Theme.faceOf("accent", false, true), "accent")
            delete Theme.ts.buttonPress; Theme.tsChanged()
        }

        function test_the_hover_control_follows_text_unless_set() {
            const p2 = Object.assign({}, pal, { text: "#e0e0e0" })
            compare(Theme.inkFrom(p2, ({}), "controlHover").colour.toString(), "#e0e0e0")
            const p3 = Object.assign({}, p2, { controlHover: "#ff8800" })
            compare(Theme.inkFrom(p3, ({}), "controlHover").colour.toString(), "#ff8800")
            verify(Theme.inkRoles.indexOf("controlHover") >= 0)
        }

        function test_the_active_button_ink_follows_the_selected_one_then_text() {
            const p2 = Object.assign({}, pal, { text: "#e0e0e0" })
            compare(Theme.inkFrom(p2, ({}), "textOnActive").colour.toString(), "#e0e0e0")
            const p3 = Object.assign({}, p2, { textOnSelected: "#112233" })
            compare(Theme.inkFrom(p3, ({}), "textOnActive").colour.toString(), "#112233")
            const p4 = Object.assign({}, p3, { textOnActive: "#ff8800" })
            compare(Theme.inkFrom(p4, ({}), "textOnActive").colour.toString(), "#ff8800")
            verify(Theme.inkRoles.indexOf("textOnActive") >= 0)
        }

        function test_title_ink_follows_dim_until_explicitly_set() {
            const palette = { textDim: { colour: "#335577", source: "gradient", params: { speed: 0 },
                                        effect: { kind: "shadow", colour: "#000000", opacity: 0.5 } } }
            const opacity = { textDim: 0.6 }
            compare(Theme.inkFrom(palette, opacity, "textOnTitle"), Theme.inkFrom(palette, opacity, "textDim"))
            compare(Theme.inkFrom(({}), ({}), "textOnTitle"), Theme.inkFrom(({}), ({}), "textDim"))
            opacity.textOnTitle = 0.8
            fuzzyCompare(Theme.inkFrom(palette, opacity, "textOnTitle").opacity, 0.8, 0.001)
            palette.textOnTitle = "#ffffff"
            compare(Theme.inkFrom(palette, opacity, "textOnTitle").colour.toString(), "#ffffff")
            compare(Theme.inkFrom(palette, opacity, "textOnTitle").source, "colour")
            compare(Theme.inkFrom(palette, opacity, "textDim").colour.toString(), "#335577")
            verify(Theme.inkRoles.indexOf("textOnTitle") >= 0)
        }

        function test_a_missing_role_falls_back_and_never_throws() {
            const r = Theme.roleFrom(pal, op, 1, "toast")
            compare(r.colour.toString(), "#222222")
            fuzzyCompare(r.opacity, 1, 0.001)
            compare(r.source, "colour")
        }

        // ink has the surface shape, its own opacity, and never the master
        function test_ink_takes_its_own_opacity_and_not_the_masters() {
            const ip = ({ text: "#e0e0e0", textDim: { colour: "#888888", blend: "multiply" } })
            const io = ({ text: 0.5, textDim: 1 })
            const t = Theme.inkFrom(ip, io, "text")
            compare(t.colour.toString(), "#e0e0e0")
            fuzzyCompare(t.opacity, 0.5, 0.001)
            const d = Theme.inkFrom(ip, io, "textDim")
            compare(d.blend, "multiply")
            // text over artwork takes text's WHOLE entry when it has none of its
            // own — source and blend included — so an adaptive text adapts on the
            // one screen where it has a picture to adapt to
            const ap = ({ text: { colour: "#e0e0e0", source: "adaptive", blend: "multiply" } })
            const o = Theme.inkFrom(ap, io, "textOverArt")
            compare(o.colour.toString(), "#e0e0e0")
            compare(o.source, "adaptive")
            compare(o.blend, "multiply")
            fuzzyCompare(o.opacity, 1, 0.001)
        }

        // The glass gate. Blur only shows where the surface is see-through, so
        // the question is the window's own alpha, not the master: a theme
        // whose master is 1 and whose window is 0.75 is see-through and must
        // still ask for blur.
        function test_translucency_is_the_window_alpha_not_the_master() {
            const solid = ({ window: "#0f0f0f" })
            // master 1, role translucent
            const r = Theme.roleFrom(solid, ({ window: 0.75 }), 1, "window")
            fuzzyCompare(r.opacity, 0.75, 0.001)
            verify(r.colour.a * r.opacity < 0.999, "a role opacity below 1 is translucent")
            // master translucent, role set to 1: the role wins, solid
            const m = Theme.roleFrom(solid, ({ window: 1 }), 0.35, "window")
            verify(m.colour.a * m.opacity > 0.999, "a role at 1 is solid under any master")
            // master translucent, role unset: the master
            const u = Theme.roleFrom(solid, ({}), 0.35, "window")
            verify(u.colour.a * u.opacity < 0.999, "a master below 1 reaches a role without its own")
            // both at 1 with an opaque colour: nothing to blur
            const o = Theme.roleFrom(solid, ({ window: 1 }), 1, "window")
            fuzzyCompare(o.colour.a * o.opacity, 1, 0.001)
            // the colour's OWN alpha counts too
            const a = Theme.roleFrom(({ window: "#800f0f0f" }), ({ window: 1 }), 1, "window")
            verify(a.colour.a * a.opacity < 0.999, "a palette alpha is translucency")
        }

        // an ink carries an effect; every field defaults, and the over-artwork
        // ink defaults to an adaptive outline
        function test_an_ink_effect_defaults_and_over_art_keeps_its_halo() {
            const e = Theme.effectOf(({ effect: { kind: "shadow", size: 3 } }))
            compare(e.kind, "shadow"); fuzzyCompare(e.size, 3, 0.001); fuzzyCompare(e.dy, 1, 0.001)
            compare(Theme.effectOf("#e0e0e0").kind, "off")
            compare(Theme.effectOf(({ effect: { kind: "nonsense" } })).kind, "off")
            const over = Theme.inkFrom(({}), ({}), "textOverArt")
            compare(over.effect.kind, "outline")
            compare(Theme.sourceOf(over.effect.colour), "adaptive")
            const plain = Theme.inkFrom(({}), ({}), "text")
            compare(plain.effect.kind, "off")
            // an adaptive effect colour is the ink's inverse at the defaults
            const c = Theme.effectColour(over.effect, Qt.color("#000000"))
            verify(c.r > 0.9 && c.g > 0.9 && c.b > 0.9, "black words get a white halo")
        }

        // One object per role per generation, and the SAME object across a
        // generation whose value did not move: a fresh object per call would
        // re-run every consumer of every role on a write to any one.
        function test_a_role_is_the_same_object_until_its_value_moves() {
            Theme.held = true
            Theme.p.card = "#101010"
            Theme.pChanged()
            const card = Theme.role("card"), window = Theme.role("window")
            verify(card === Theme.role("card"), "twice in one generation is once")
            Theme.p.window = "#202020"
            Theme.pChanged()
            compare(Theme.role("window").colour.toString(), "#202020", "the role that moved is re-read")
            verify(Theme.role("window") !== window)
            verify(Theme.role("card") === card, "the role that did not keeps its object")
            const ink = Theme.inkRole("text")
            Theme.pChanged()
            verify(Theme.inkRole("text") === ink, "an ink too")
            Theme.p.text = "#ff8800"
            Theme.pChanged()
            compare(Theme.inkRole("text").colour.toString(), "#ff8800")
            // and a palette mutated with no signal at all
            Theme.p.card = "#303030"
            Theme.invalidateRoles()
            compare(Theme.role("card").colour.toString(), "#303030")
            delete Theme.p.card; delete Theme.p.window; delete Theme.p.text
            Theme.pChanged()
            Theme.held = false
        }

        function test_roleColour_folds_opacity_into_alpha() {
            // the live Theme has no backend under the test runner, so this
            // reads the fallbacks: window #0f0f0f at scale 1
            const c = Theme.roleColour("window")
            fuzzyCompare(c.a, 1, 0.001)
        }
    }
}
