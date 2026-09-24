pragma Singleton
import QtQuick

// Theme singleton over ThemeBackend (C++ ThemeStore: resolved palette and
// merged settings). Components use only this, never ThemeBackend directly.
// Format v3: a palette entry is a role (see the top of ThemeStore.cpp). role(name)
// gives the whole role for Surface.qml; the same-named property gives the colour
// with opacity folded in, for plain Rectangles.
QtObject {
    readonly property var p: typeof ThemeBackend !== "undefined" ? ThemeBackend.palette : ({})
    readonly property var ts: typeof ThemeBackend !== "undefined" ? ThemeBackend.settings : ({})
    // Bumped on palette change to end Surface/BlendSurface latches; otherwise a
    // theme that styled every role leaves its chains, hidden but still walked, in one
    // that styles none (Dark Glass after a bevelled theme: 354 vs 232ms polish/drag).
    property int paletteGen: 0
    readonly property Connections paletteWatch: Connections {
        target: typeof ThemeBackend !== "undefined" ? ThemeBackend : null
        function onPaletteChanged() { Theme.paletteGen++ }
    }

    // Default backdrop for adaptive surfaces: Main sets it once to the background
    // layer. A ShaderEffectSource reads only its own window, so Surface checks the
    // window and the settings, EQ and metadata windows fall back to hardware inversion.
    property Item backdrop: null

    // One fill cache per window, registered here. Shared masks and edge fields are
    // layers, whose textures belong to the window they render in, so the cache is an
    // item under each contentItem (FillCache.qml). The window's child list is the
    // register, not a Map: V4 holds QObject wrappers weakly, so a collected wrapper
    // returns as a new object and a Map keyed on it misses and builds a second cache.
    property var fillCacheComp: null
    function fillCache(win) {
        if (!win || !win.contentItem) return null
        const kids = win.contentItem.children
        for (let i = 0; i < kids.length; ++i)
            if (kids[i].objectName === "fillCache") return kids[i]
        if (!fillCacheComp)
            fillCacheComp = Qt.createComponent(Qt.resolvedUrl("../components/FillCache.qml"))
        if (fillCacheComp.status !== Component.Ready) return null
        return fillCacheComp.createObject(win.contentItem)
    }
    // Adaptive readers on screen. `anyAdaptive` is about the palette; a role used
    // only by a menu would otherwise run the offscreen pass every frame. HueLum is the
    // only backdrop sampler, so it holds while ready and visible.
    property int adaptiveUsers: 0
    property int adaptiveLive: 0    // every adaptive reader on screen, whatever it reads

    // Whether any layer of any role is adaptive (not just the bottom one: an
    // adaptive layer over a plain colour still reads the ground). The ground texture
    // costs a full-window offscreen pass a theme that adapts nothing should not pay.
    readonly property bool anyAdaptive: {
        for (let i = 0; i < surfaceRoles.length; ++i)
            if (hasAdaptive(p[surfaceRoles[i]])) return true
        for (let i = 0; i < inkRoles.length; ++i)
            if (hasAdaptive(p[inkRoles[i]])) return true
        return false
    }

    readonly property var surfaceRoles: ["window", "page", "chrome", "title", "player", "panel", "dialog", "menu",
                                         "card", "button", "input", "hover", "buttonHover", "buttonPress", "closeFace", "closeFaceHover", "selected", "cardSelected", "toast",
                                         "scrollbar", "tooltip", "skeleton", "panelHeader",
                                         "sliderTrack", "toggleOff", "buttonActive", "scrubberTrack"]
    // Floating over CONTENT rather than over the desktop: these keep an
    // absolute opacity and ignore opacityScale, or a translucent theme would
    // put the view's own text through the panel covering it.
    readonly property var floatingRoles: ["panel", "dialog", "menu", "toast", "tooltip"]

    // ---- reading an entry -------------------------------------------------
    // An entry is a colour string or an object; these answer the same for either.
    // Where only one value can be had, a stack stands for its bottom layer (~130 plain
    // Texts take only a colour); whole-stack drawers ask for `layers`. Layers from C++
    // are a QVariantList, which fails Array.isArray, hence isList.
    function isList(x) { return x !== null && x !== undefined && typeof x === "object" && typeof x.length === "number" }
    function base(v) {
        return (v !== null && typeof v === "object" && isList(v.layers) && v.layers.length)
               ? v.layers[0] : v
    }
    function colorOf(raw, fallback) {
        const v = base(raw)
        const fb = fallback !== undefined && fallback !== null ? fallback : "#000000"
        if (v === undefined || v === null) return Qt.color(fb)
        if (typeof v === "object") return Qt.color(v.colour !== undefined ? v.colour : fb)
        const s = String(v)
        // Qt.color throws on anything that is not a colour, and a throwing
        // binding takes down everything downstream of it — so a value that
        // cannot be one is the fallback, not an exception.
        if (s.length === 0 || s.indexOf(":") >= 0) return Qt.color(fb)
        return Qt.color(s)
    }
    // A stack's blend is its bottom layer's: that layer meets the surface's
    // backdrop, which BlendSurface applies. Upper layers blend inside the fill renderer.
    function blendOf(raw) {
        const v = base(raw)
        return (v !== null && typeof v === "object" && v.blend) ? String(v.blend) : ""
    }
    // "colour", "adaptive", or a styled kind
    // THE FILLS: melo's own in styled.frag, by index, and any a plugin ships
    // as a .qsb of its own, named "<pluginId>.<fillId>". Each kind declares
    // whether it reads the base colour and/or the editable palette.
    readonly property var builtinFills: [
        // base: the kind paints the entry's own colour. palette: the kind takes a list
        // of colours; with none it reverts to its classic look (prism = cosine rainbow,
        // aurora = green/violet, fire = gold to white). The shader draws the first six stops.
        { kind: "gradient", name: "gradient", base: true,  palette: true },
        { kind: "rainbow",  name: "rainbow",  base: false, palette: false },
        { kind: "prism",    name: "prism",    base: false, palette: true },
        { kind: "foil",     name: "foil",     base: true,  palette: true },
        { kind: "lava",     name: "lava",     base: true,  palette: true },
        { kind: "plasma",   name: "plasma",   base: false, palette: true },
        { kind: "metal",    name: "metal",    base: true,  palette: false },
        { kind: "fire",     name: "fire",     base: true,  palette: true },
        { kind: "aurora",   name: "aurora",   base: true,  palette: true },
        { kind: "image",    name: "image",    base: false, palette: false, image: true },
        // Appended, never reordered: a fill's place here is its code
        { kind: "gloss",    name: "gloss",    base: true,  palette: false },
        { kind: "brushed",  name: "brushed",  base: true,  palette: false },
        { kind: "aero",     name: "aero",     base: true,  palette: false },
        { kind: "agate",    name: "agate",    base: true,  palette: true },
        { kind: "opal",     name: "opal",     base: true,  palette: true },
        { kind: "nebula",   name: "nebula",   base: true,  palette: true },
        { kind: "mercury",  name: "mercury",  base: true,  palette: true },
        { kind: "lucent",   name: "lucent",   base: true,  palette: true },
        { kind: "gyroid",   name: "gyroid",   base: true,  palette: true },
        { kind: "kaleido",  name: "kaleido",  base: true,  palette: true },
        { kind: "raster",   name: "raster",   base: true,  palette: true },
        { kind: "bevel",    name: "bevel",    base: true,  palette: true, shape: true },
        { kind: "contour",  name: "contour",  base: true,  palette: true, shape: true },
        { kind: "rim",      name: "rim",      base: true,  palette: true, shape: true },
        { kind: "trace",    name: "trace",    base: true,  palette: true, shape: true },
        { kind: "tidal",    name: "tidal",    base: true,  palette: true, shape: true },
        { kind: "cloud",    name: "cloud",    base: true,  palette: true },
        { kind: "toon",     name: "toon",     base: true,  palette: true, shape: true },
        { kind: "comic",    name: "comic",    base: true,  palette: true },
        { kind: "doodle",   name: "doodle",   base: true,  palette: true, shape: true },
        { kind: "dome",     name: "dome",     base: true,  palette: true, shape: true }
    ]
    readonly property var pluginFills: {
        if (typeof PluginFills === "undefined" || !PluginFills) return []
        const dep = PluginFills.generation
        return PluginFills.all()
    }
    readonly property var fills: builtinFills.concat(pluginFills)
    readonly property var styledKinds: fills.map(f => f.kind)
    function isStyled(source) { return styledKinds.indexOf(source) >= 0 }
    // Filters: kinds that draw nothing, only change the layers under them (an
    // adjustment layer / backdrop-filter). Append only: a filter's index is its code.
    // Options live in fillOptionTables.
    readonly property var filterKinds: [
        { kind: "pixelate",  name: "pixelate"  },
        { kind: "posterize", name: "posterize" },
        { kind: "threshold", name: "threshold" },
        { kind: "invert",    name: "invert"    },
        { kind: "grey",      name: "greyscale" },
        { kind: "sepia",     name: "sepia"     },
        { kind: "hueshift",  name: "hue shift" },
        { kind: "contrast",  name: "contrast"  },
        { kind: "saturate",  name: "saturate"  },
        { kind: "dither",    name: "dither"    },
        { kind: "scanlines", name: "scanlines" }
    ]
    readonly property var filterNames: filterKinds.map(f => f.kind)
    function isFilter(source) { return filterNames.indexOf(source) >= 0 }
    // 1-based, the branch in stackblend.frag; 0 is no filter
    function filterIndex(kind) { return filterNames.indexOf(kind) + 1 }
    function filterName(kind) { const i = filterNames.indexOf(kind); return i >= 0 ? filterKinds[i].name : kind }
    // Whether any layer has a given source (`source` is only the bottom layer's).
    // Asked of every role, so these allocate nothing: going through layersOf() filled
    // the JS heap and triggered GUI-thread GC.
    function layerAt(v, i) {
        const ls = (v !== null && typeof v === "object" && isList(v.layers)) ? v.layers : null
        return ls === null ? (i === 0 ? v : undefined) : ls[i]
    }
    function layerCount(v) {
        const ls = (v !== null && typeof v === "object" && isList(v.layers)) ? v.layers : null
        return ls === null ? 1 : ls.length
    }
    function anyStyled(v) {
        const n = layerCount(v)
        for (let i = 0; i < n; ++i) if (isStyled(sourceOf(layerAt(v, i)))) return true
        return false
    }
    // Does this need the layer renderer (layered, below). A fill does, and so
    // does a stack of plain colours — nothing else composites them, and the
    // flat Rectangle a surface falls back to can only paint one colour.
    function anyFilter(v) {
        const n = layerCount(v)
        for (let i = 0; i < n; ++i) if (isFilter(sourceOf(layerAt(v, i)))) return true
        return false
    }
    function layered(v) { return anyStyled(v) || anyFilter(v) || layersOf(v).length > 1 }
    function hasAdaptive(v) {
        const n = layerCount(v)
        for (let i = 0; i < n; ++i) if (sourceOf(layerAt(v, i)) === "adaptive") return true
        return false
    }
    function fillOf(kind) {
        for (let i = 0; i < fills.length; ++i) if (fills[i].kind === kind) return fills[i]
        return null
    }
    // 1-based index into styled.frag for a built-in, 0 for a plugin's own shader
    function fillIndex(kind) { const i = builtinFills.findIndex(f => f.kind === kind); return i + 1 }
    function fillShader(kind) { const f = fillOf(kind); return f && f.shader ? f.shader : "" }
    function fillBase(kind) { const f = fillOf(kind); return f ? f.base === true || (f.colours !== undefined && f.colours >= 1) : false }
    function fillPalette(kind) { const f = fillOf(kind); return f ? f.palette === true || (f.colours !== undefined && f.colours >= 2) : false }
    function fillName(kind) { const f = fillOf(kind); return f ? f.name : kind }
    function fillShape(kind) { const f = fillOf(kind); return f ? f.shape === true : false }
    // An entry as one hex code, and back. Letter tags past f separate segments;
    // every lever is a byte.
    //   #RRGGBB[AA]                          colour
    //   sKKSSCCAA[RRGGBB]                    fill: kind, speed, scale, angle, colour2 when the kind takes one
    //   fKK                                  a filter, by its place in filterKinds; no levers
    //   kN<byte per option>                  the kind's own options, in its table's order, each
    //                                        a byte across the option's range
    //   pHHHHSSCCAA[RRGGBB]                  a plugin's fill: HHHH is the 16-bit hash of "pluginId.fillId"
    //   cHHLLSSAA                            contrast: hue, lum, sat, opacity
    //   bK                                   blend: 1 multiply 2 screen 3 darken 4 lighten 5 subtract
    //   oAA                                  this layer's opacity
    //   tAA                                  this layer's phase, 0..1 of a turn
    //   mKAA                                 this layer's mask: kind (1 edge, 2 core), band in px
    //   wK                                   what the pattern is anchored to (1 item, 2 scroll)
    //   +                                    the next layer, bottom to top
    //   eKSSFFXXYYAA(RRGGBB|cHHLLSSAA)       effect: kind (1 glow 2 outline 3 shadow), size, soft, dx, dy,
    //                                        opacity, then its colour or a contrast — once, after the stack
    // Only Copy/Paste read codes, so length is unconstrained. A code from a newer melo
    // (unknown tag, truncated segment) keeps what parsed before it; a malformed
    // colour is rejected.
    // Bytes: signed levers (speed, contrast amounts) are (v + 1) / 2; dx, dy are
    // (v + 8) / 16; scale and size are v / 8; angle is v / 360; opacity and softness
    // are v. A plugin fill decodes only where the plugin is installed, else reads as
    // its colour. An image fill's path is not in the code.
    // Append only: the index is what a saved code carries, and stackblend.frag's mode
    // numbers are these indices. The first six are hardware blend factors; the rest
    // read the destination, which in a stack means compositing the layers below first.
    readonly property var blendCodes: ["", "multiply", "screen", "darken", "lighten", "subtract",
                                       "overlay", "colour dodge", "colour burn", "hard light",
                                       "soft light", "difference", "exclusion",
                                       "hue", "saturation", "colour", "luminosity",
                                       // past the W3C set: Krita's and GIMP's, one line each
                                       "linear burn", "linear dodge", "linear light", "vivid light",
                                       "pin light", "hard mix", "divide", "grain extract",
                                       "grain merge", "geometric mean", "negation", "reflect",
                                       "glow", "allanon"]
    // The six a BlendRect can do on its own. The rest need stackblend.frag,
    // and so only exist between the layers of a stack — never between an entry
    // and the window behind it, which nothing captures.
    readonly property var hardwareBlends: ["", "multiply", "screen", "darken", "lighten", "subtract"]
    function blendIsHardware(name) { return hardwareBlends.indexOf(String(name || "")) >= 0 }
    // Does this stack need the compositing chain. a mode past the blend
    // factors has to read what is under it, and so does darken — it is a Min
    // blend, which BlendRect refuses for a texture. One definition, because
    // the renderer and the number the picker shows must not drift apart.
    function stackChains(layers) {
        for (let i = 1; i < layers.length; ++i) {
            if (isFilter(layers[i].source)) return true   // it reads what is under it
            const b = String(layers[i].blend || "")
            if (b.length > 0 && (!blendIsHardware(b) || b === "darken")) return true
        }
        return false
    }
    // Draw cost of one instance of a stack: alpha-over and blend-factor layers are
    // one draw each; the chain is a render target per rung (a filter rung one pass,
    // a fill rung two). Inks instantiate per label, so this multiplies by label count.
    function stackPasses(v) {
        const ls = layersOf(v)
        if (!stackChains(ls)) return ls.length
        let fills = 0
        for (let i = 0; i < ls.length; ++i) if (!isFilter(ls[i].source)) ++fills
        // The bottom layer has no rung: its own texture is what the first
        // rung composites onto, so a rung there would copy it. Except when
        // its own alpha has to be applied first, which only a rung can do.
        const b = ls[0]
        const opaque = !isFilter(b.source)
                       && (b.opacity !== undefined ? b.opacity : 1) * colorOf(b, "#ffffff").a >= 1
        return fills + ls.length + (opaque ? 0 : 1)
    }
    function blendIndex(name) { const i = blendCodes.indexOf(String(name || "")); return i > 0 ? i : 0 }
    // the whole shape, a band at its edge, or everything inside that band
    readonly property var maskModes: ["all", "edge", "core"]
    // What the pattern is anchored to:
    //   window  one pattern across the window; moving items slide across it (default)
    //   item    restarts in each item
    //   scroll  one pattern across the scrolled content; items keep their slice
    readonly property var fillSpaces: ["window", "item", "scroll"]
    // A kind's own options: what each of the eight par2/par3 floats means for that
    // kind (name, label, range, default, slot). The picker builds its settings from
    // this table. A kind that declares none pays for two zeroed uniforms.
    readonly property var fillOptionTables: ({
        image:    [{ name: "fit", label: "fit", from: 0, to: 5, step: 1, value: 0, slot: 0 },
                   { name: "anchor", label: "anchor", from: 0, to: 8, step: 1, value: 0, slot: 1 },
                   // -1 follows the anchor; an explicit point stays there as zoom changes.
                   { name: "focusX", label: "focus x", from: -1, to: 1, step: 0.01, value: -1, slot: 2 },
                   { name: "focusY", label: "focus y", from: -1, to: 1, step: 0.01, value: -1, slot: 3 },
                   { name: "sliceLeft", label: "left", from: 0, to: 255, step: 1, value: 8, slot: 4 },
                   { name: "sliceTop", label: "top", from: 0, to: 255, step: 1, value: 8, slot: 5 },
                   { name: "sliceRight", label: "right", from: 0, to: 255, step: 1, value: 8, slot: 6 },
                   { name: "sliceBottom", label: "bottom", from: 0, to: 255, step: 1, value: 8, slot: 7 }],
        // Stop positions across the item; 0 is even spacing. Placed stops let a ramp
        // hold then fall (an XP caption bar), which even stops cannot express; two stops
        // at one place make a hard line.
        gradient: [{ name: "repeat",   label: "repeat",   from: 0.1,  to: 4,    step: 0.05, value: 0.5,  slot: 0, when: { fit: 0 } },
                   { name: "fit",      label: "span",     toggle: ["repeat", "item", "bands"],            value: 0,    slot: 1 },
                   { name: "stop1",    label: "at 1",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 2, when: { fit: 1 }, needsStops: true },
                   { name: "stop2",    label: "at 2",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 3, when: { fit: 1 }, needsStops: true },
                   { name: "stop3",    label: "at 3",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 4, when: { fit: 1 }, needsStops: true },
                   { name: "stop4",    label: "at 4",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 5, when: { fit: 1 }, needsStops: true },
                   { name: "stop5",    label: "at 5",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 6, when: { fit: 1 }, needsStops: true },
                   { name: "stop6",    label: "at 6",     from: 0,    to: 0.95, step: 0.005, value: 0,   slot: 7, when: { fit: 1 }, needsStops: true }],

        // A lit dome: colours land by angle from the light, first at the lit pole,
        // last on the unlit side, both ends holding (a broad highlight and a flat far
        // side). With no colours the entry's own colour is lit.
        dome:     [{ name: "depth",    label: "depth",    from: 0,    to: 1,    step: 0.01, value: 0.9,  slot: 0 },
                   { name: "light",    label: "light",    from: 0.02, to: 1,    step: 0.01, value: 0.55, slot: 1 },
                   { name: "bias",     label: "bias",     from: 0,    to: 1,    step: 0.01, value: 0,    slot: 2 },
                   { name: "spread",   label: "spread",   from: 0.2,  to: 3,    step: 0.01, value: 1,    slot: 3 },
                   { name: "spec",     label: "shine",    from: 0,    to: 1,    step: 0.01, value: 0.12, slot: 4 },
                   { name: "gloss",    label: "tightness", from: 1,   to: 64,   step: 1,    value: 16,   slot: 5 },
                   { name: "bounce",   label: "bounce",   from: 0,    to: 1,    step: 0.01, value: 0,    slot: 6 },
                   { name: "reach",    label: "reach",    from: 0,    to: 31,   step: 0.5,  value: 0,    slot: 7 }],

        foil:     [{ name: "bands",    label: "bands",    from: 1,    to: 24,   step: 0.5,  value: 7,    slot: 0 },
                   { name: "sparkle",  label: "sparkle",  from: 0,    to: 1,    step: 0.01, value: 0.3,  slot: 1 }],
        brushed:  [{ name: "grain",    label: "grain",    from: 0,    to: 1,    step: 0.01, value: 0.22, slot: 0 },
                   { name: "fineness", label: "fineness", from: 100,  to: 2400, step: 10,   value: 900,  slot: 1 },
                   { name: "sheen",    label: "sheen",    from: 0,    to: 1,    step: 0.01, value: 0.18, slot: 2 }],
        aero:     [{ name: "horizon",  label: "horizon",  from: 0,    to: 0.95, step: 0.01, value: 0.38, slot: 0 },
                   { name: "streaks",  label: "streaks",  from: 0,    to: 1,    step: 0.01, value: 0.32, slot: 1 }],
        raster:   [{ name: "pixels",   label: "pixels",   from: 12,   to: 140,  step: 1,    value: 48,   slot: 0 },
                   { name: "trail",    label: "trail",    from: 3,    to: 48,   step: 1,    value: 18,   slot: 1 }],
        cloud:    [{ name: "puff",     label: "puff",     from: 1,    to: 14,   step: 0.1,  value: 4,    slot: 0 },
                   { name: "density",  label: "density",  from: 0,    to: 2,    step: 0.02, value: 1,    slot: 1 },
                   { name: "softness", label: "softness", from: 0.2,  to: 2,    step: 0.02, value: 1,    slot: 2 },
                   { name: "relief",   label: "relief",   from: 0,    to: 2,    step: 0.02, value: 0.55, slot: 3 },
                   { name: "light",    label: "light", unit: "°", from: 0, to: 360, step: 1, value: 0, slot: 4 },
                   { name: "billow",   label: "billow",   from: 0,    to: 2,    step: 0.02, value: 1,    slot: 5, motion: true },
                   { name: "wind",     label: "wind",     from: -2,   to: 2,    step: 0.02, value: 1,    slot: 6, motion: true },
                   { name: "shade",    label: "shade",    from: 0,    to: 1,    step: 0.02, value: 0.3,  slot: 7 }],
        lava:     [{ name: "heat",     label: "heat",     from: 0.3,  to: 0.78, step: 0.01, value: 0.52, slot: 0 }],
        plasma:   [{ name: "waves",    label: "waves",    from: 2,    to: 40,   step: 0.5,  value: 10,   slot: 0 }],
        metal:    [{ name: "horizon",  label: "horizon",  from: 0.05, to: 0.95, step: 0.01, value: 0.5,  slot: 0 },
                   { name: "sheen",    label: "sheen",    from: 0,    to: 1,    step: 0.01, value: 0.5,  slot: 1 }],
        fire:     [{ name: "reach",    label: "reach",    from: 0.6,  to: 3.2,  step: 0.05, value: 1.7,  slot: 0 }],
        aurora:   [{ name: "bands",    label: "bands",    from: 4,    to: 60,   step: 0.5,  value: 22,   slot: 0 }],
        // Ink (outline) and relief (cel shadow) are independent; lower relief is a
        // deeper shadow, never another black edge. Both default to 1. Edge is auto (share
        // of the smaller side * scale * percentage) or px. `toggle` options are bytes;
        // `when` picks visible rows. Append only, so older codes' bytes still land.
        toon:     [{ name: "ink",      label: "ink",      from: 0,    to: 4,    step: 0.05, value: 1,    slot: 0 },
                   { name: "relief",   label: "relief",   from: 0.15, to: 1.8,  step: 0.01, value: 1,    slot: 1 },
                   { name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } },
                   // Append, even when using a vacant earlier uniform slot:
                   // compact codes store options in TABLE order, not slot order.
                   { name: "softness", label: "softness", from: 0,    to: 1,    step: 0.02, value: 0,    slot: 2 },
                   { name: "shine",    label: "shine",    from: 0,    to: 1,    step: 0.02, value: 0.85, slot: 6 },
                   { name: "bulge",    label: "bulge",    from: 0.25, to: 3,    step: 0.05, value: 1,    slot: 7 }],
        bevel:    [{ name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } },
                   { name: "height",   label: "height",   from: 0,    to: 3,    step: 0.05, value: 1,    slot: 0 },
                   { name: "shine",    label: "shine",    from: 0,    to: 2,    step: 0.02, value: 0.85, slot: 1 },
                   { name: "sharpness",label: "sharpness",from: 2,    to: 96,   step: 1,    value: 18,   slot: 2 },
                   { name: "ambient",  label: "ambient",  from: 0,    to: 1,    step: 0.02, value: 0.3,  slot: 6 },
                   { name: "inset",    label: "face", toggle: ["raised", "inset"],                  value: 0,    slot: 7 }],
        // ...and how far in from the edge a contour's rings reach: auto is the
        // field's usual 31px, times the percentage; the field is measured as
        // far as either asks, up to 128
        contour:  [{ name: "depth",     label: "depth", unit: "px", from: 1,    to: 128,  step: 1,    value: 31,   slot: 2, when: { depthAuto: 0 } },
                   { name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } },
                   { name: "depthAuto", label: "depth", toggle: ["px", "auto"],                        value: 1,    slot: 6 },
                   { name: "depthScale",label: "depth", unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 7, when: { depthAuto: 1 } }],
        rim:      [{ name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } }],
        trace:    [{ name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } }],
        tidal:    [{ name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } }],
        doodle:   [{ name: "edge",      label: "edge",  unit: "px", from: 0.5,  to: 24,   step: 0.5,  value: 4,    slot: 3, when: { edgeAuto: 0 } },
                   { name: "edgeAuto",  label: "edge",  toggle: ["px", "auto"],                        value: 1,    slot: 4 },
                   { name: "edgeScale", label: "edge",  unit: "%",  from: 25,   to: 400,  step: 5,    value: 100,  slot: 5, when: { edgeAuto: 1 } }],
        // THE FILTERS. A filter is nothing but its options.
        pixelate:  [{ name: "size",     label: "size",     from: 2,    to: 64,   step: 1,    value: 8,    slot: 0 }],
        posterize: [{ name: "levels",   label: "levels",   from: 2,    to: 16,   step: 1,    value: 4,    slot: 0 }],
        threshold: [{ name: "level",    label: "level",    from: 0.02, to: 0.98, step: 0.01, value: 0.5,  slot: 0 }],
        hueshift:  [{ name: "degrees",  label: "degrees",  from: 0,    to: 360,  step: 1,    value: 180,  slot: 0 }],
        contrast:  [{ name: "amount",   label: "amount",   from: 0,    to: 3,    step: 0.05, value: 1.5,  slot: 0 }],
        saturate:  [{ name: "amount",   label: "amount",   from: 0,    to: 3,    step: 0.05, value: 2,    slot: 0 }],
        dither:    [{ name: "size",     label: "size",     from: 1,    to: 8,    step: 1,    value: 2,    slot: 0 },
                    { name: "levels",   label: "levels",   from: 2,    to: 8,    step: 1,    value: 2,    slot: 1 },
                    { name: "strength", label: "strength", from: 0,    to: 1,    step: 0.05, value: 1,    slot: 2 }],
        scanlines: [{ name: "pitch",    label: "pitch",    from: 2,    to: 16,   step: 1,    value: 4,    slot: 0 },
                    { name: "darkness", label: "darkness", from: 0,    to: 1,    step: 0.05, value: 0.5,  slot: 1 }]
    })
    // How far in the edge field has to be measured for a stack: 32, the
    // field's usual reach, or the deepest contour in it rounded up to 64 or
    // 128 — the scan past 32 costs, so only a stack that asks pays.
    function fieldReach(layers) {
        let deep = 32
        const ls = isList(layers) ? layers : layersOf(layers)
        for (let i = 0; i < ls.length; ++i) {
            if (sourceOf(ls[i]) !== "contour") continue
            const d = contourDepth(styledOf(ls[i]))
            if (d > deep) deep = d
        }
        return deep <= 32 ? 32 : deep <= 64 ? 64 : 128
    }
    // how deep a contour's rings go, in pixels: what the shader computes too
    function contourDepth(pr) {
        const o = (pr && pr.own) || ({})
        const auto = o.depthAuto === undefined ? 1 : parseFloat(o.depthAuto)
        if (auto > 0.5) return 31 * (o.depthScale !== undefined ? parseFloat(o.depthScale) : 100) / 100
        return o.depth !== undefined ? parseFloat(o.depth) : 31
    }
    function fillOptions(kind) {
        const t = fillOptionTables[kind]
        return Array.isArray(t) ? t : []
    }
    // Four of a kind's slots as a vector, from `from`: the table says which
    // slot each option takes, and an option a params object does not name is
    // at its default. What par2 and par3 are made of, for a fill's shader and
    // a filter rung alike.
    function optionVec(kind, pr, from) {
        const t = fillOptions(kind), o = (pr && pr.own) || ({})
        const at = (i) => {
            for (let j = 0; j < t.length; ++j)
                if (t[j].slot === i) return parseFloat(o[t[j].name] !== undefined ? o[t[j].name] : t[j].value) || 0
            return 0
        }
        return Qt.vector4d(at(from), at(from + 1), at(from + 2), at(from + 3))
    }
    function hex2(v) { const n = Math.max(0, Math.min(255, Math.round(v))); return (n < 16 ? "0" : "") + n.toString(16) }
    function byteOf(code, i) { return parseInt(code.substr(i, 2), 16) }
    function fillHash(kind) {   // FNV-1a, 16 bits
        let h = 0x811c9dc5
        for (let i = 0; i < kind.length; ++i) { h ^= kind.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 }
        return ((h >>> 16) ^ (h & 0xffff)) & 0xffff
    }
    function fillKindOfHash(h) {
        for (let i = 0; i < pluginFills.length; ++i) if (fillHash(pluginFills[i].kind) === h) return pluginFills[i].kind
        return ""
    }
    function entryToCode(v) {
        if (v === null || v === undefined) return ""
        if (typeof v !== "object") return String(v)
        const ls = isList(v.layers) && v.layers.length > 1 ? v.layers : [v]
        let out = ls.map(layerCode).join("+")
        // The halo is the entry's, not a layer's — it is drawn around the
        // stack, so it is written once, after it.
        const e = effectOf(v)
        if (e.kind !== "off") {
            out += "e" + ({ glow: 1, outline: 2, shadow: 3 })[e.kind]
                 + hex2(e.size / 8 * 255) + hex2(e.soft * 255) + hex2((e.dx + 8) / 16 * 255) + hex2((e.dy + 8) / 16 * 255)
                 + hex2(e.opacity * 255)
            // the effect's colour takes the entry's own grammar: contrast, or
            // a colour with a fill after it
            if (sourceOf(e.colour) === "adaptive") out += contrastCode(e.colour)
            else {
                out += colorOf(e.colour, "#000000").toString().slice(1, 7)
                if (isStyled(sourceOf(e.colour))) out += fillCode(e.colour)
            }
        }
        return out
    }
    function layerCode(v) {
        let out = colorOf(v, "#ffffff").toString()
        const src = sourceOf(v)
        if (src === "adaptive") out += contrastCode(v)
        else if (src !== "colour") out += fillCode(v)
        // A nibble holds fifteen. `b` is what every saved code already uses and
        // its meaning cannot change, so the modes past it take `n` and a byte.
        const bi = blendCodes.indexOf(blendOf(v))
        if (bi > 0 && bi < 16) out += "b" + bi.toString(16)
        else if (bi >= 16) out += "n" + hex2(bi)
        const op = (v !== null && typeof v === "object" && v.opacity !== undefined)
                 ? Math.max(0, Math.min(1, parseFloat(v.opacity))) : 1
        if (op < 1) out += "o" + hex2(op * 255)
        const phase = (v !== null && typeof v === "object" && v.phase !== undefined)
                    ? Math.max(0, Math.min(1, parseFloat(v.phase))) : 0
        if (phase > 0) out += "t" + hex2(phase * 255)
        const sp = v !== null && typeof v === "object" ? fillSpaces.indexOf(String(v.space)) : -1
        if (sp > 0) out += "w" + sp.toString(16)
        const mk = v !== null && typeof v === "object" ? maskModes.indexOf(String(v.mask)) : -1
        if (mk > 0) {
            const d = (v.maskDist !== undefined) ? Math.max(0, Math.min(31.5, parseFloat(v.maskDist))) : 3
            out += "m" + mk.toString(16) + hex2(d / 31.5 * 255)
            const sf = (v.maskSoft !== undefined) ? Math.max(0, Math.min(31.5, parseFloat(v.maskSoft))) : 0
            if (sf > 0) out += "q" + hex2(sf / 31.5 * 255)
        }
        return out
    }
    function contrastCode(v) {
        const a = adaptiveOf(v)
        return "c" + hex2((a.x + 1) / 2 * 255) + hex2((a.y + 1) / 2 * 255) + hex2((a.z + 1) / 2 * 255) + hex2(a.w * 255)
    }
    // A kind's own options, a byte each across the option's range, in the
    // order its table declares — which is append-only, so an older code reads
    // the options it has and leaves the rest at their defaults.
    function optionsCode(kind, pr) {
        const t = fillOptions(kind)
        if (t.length === 0) return ""
        const own = pr.own || ({})
        let out = "k" + Math.min(15, t.length).toString(16)
        for (let i = 0; i < Math.min(15, t.length); ++i) {
            const o = t[i], v = own[o.name] !== undefined ? parseFloat(own[o.name]) : o.value
            const lo = optFrom(o), hi = optTo(o)
            out += hex2((v - lo) / (hi - lo) * 255)
        }
        return out
    }
    // an option's range; a toggle has none written down and runs 0 to its last choice
    function optFrom(o) { return o.from !== undefined ? o.from : 0 }
    function optTo(o) { return o.to !== undefined ? o.to : (isList(o.toggle) ? o.toggle.length - 1 : 1) }
    function fillCode(v) {
        const src = sourceOf(v), pr = styledOf(v)
        // a filter has no levers: its kind, then its options
        if (isFilter(src)) return "f" + hex2(filterIndex(src)) + optionsCode(src, pr)
        const idx = fillIndex(src)
        let out = idx > 0 ? "s" + hex2(idx) : "p" + ("000" + fillHash(src).toString(16)).slice(-4)
        out += hex2((pr.speed + 1) / 2 * 255) + hex2(pr.scale / 8 * 255) + hex2(pr.angle / 360 * 255)
        // the palette: a count nibble, then a colour per stop. Six digits of
        // RGB, always: a colour with alpha prints as #aarrggbb, and its
        // first six digits, `aarrgg`, are a different colour.
        if (fillPalette(src)) {
            const n = Math.min(15, pr.colours.length)
            out += n.toString(16)
            const alphas = []
            let translucent = false
            for (let i = 0; i < n; ++i) {
                const col = colorOf(pr.colours[i], "#ffffff")
                const t = col.toString()
                out += t.length >= 9 ? t.slice(3, 9) : t.slice(1, 7)
                alphas.push(col.a)
                if (col.a < 0.999) translucent = true
            }
            // ...and the alphas after them, only when one of them has any, so
            // every code ever written still reads as what it says. A build
            // that predates this stops at the tag and keeps the colours.
            if (translucent) {
                out += "a" + n.toString(16)
                for (let i = 0; i < n; ++i) out += hex2(alphas[i] * 255)
            }
        }
        return out + optionsCode(src, pr)
    }
    // a fill segment at i: its kind and params, and where it ends
    function parseFill(c, i) {
        const isHex = (x) => /^[0-9a-f]+$/.test(x)
        const sgn = (b) => Number((b / 255 * 2 - 1).toFixed(2))
        let kind, j, params
        if (c[i] === "f") {
            kind = filterKinds[byteOf(c, i + 1) - 1] ? filterKinds[byteOf(c, i + 1) - 1].kind : ""
            j = i + 3
            params = ({})
        } else {
            if (c[i] === "s") { kind = builtinFills[byteOf(c, i + 1) - 1] ? builtinFills[byteOf(c, i + 1) - 1].kind : ""; j = i + 3 }
            else { kind = fillKindOfHash(parseInt(c.substr(i + 1, 4), 16)); j = i + 5 }
            params = ({ speed: sgn(byteOf(c, j)), scale: Number((byteOf(c, j + 2) / 255 * 8).toFixed(2)),
                        angle: Math.round(byteOf(c, j + 4) / 255 * 360) })
            j += 6
            if (kind && fillPalette(kind) && isHex(c.substr(j, 1))) {
                const n = parseInt(c[j], 16); j += 1
                const cols = []
                for (let k = 0; k < n && isHex(c.substr(j, 6)); ++k) { cols.push("#" + c.substr(j, 6)); j += 6 }
                // an alpha per stop, if the code carries them
                if (c[j] === "a" && isHex(c.substr(j + 1, 1))) {
                    const m = parseInt(c[j + 1], 16); j += 2
                    for (let k = 0; k < m && isHex(c.substr(j, 2)); ++k) {
                        const a = byteOf(c, j)
                        if (k < cols.length && a < 255) cols[k] = "#" + hex2(a) + cols[k].slice(1)
                        j += 2
                    }
                }
                params.colours = cols
            }
        }
        // the kind's own options, if the code carries them and this build
        // knows the kind: read as many as both sides have
        if (c[j] === "k" && isHex(c.substr(j + 1, 1))) {
            const n = parseInt(c[j + 1], 16), t = kind ? fillOptions(kind) : []
            j += 2
            for (let k = 0; k < n && isHex(c.substr(j, 2)); ++k) {
                if (k < t.length) {
                    const o = t[k], v = optFrom(o) + byteOf(c, j) / 255 * (optTo(o) - optFrom(o))
                    params[o.name] = Number(v.toFixed(o.step >= 1 || isList(o.toggle) ? 0 : 3))
                }
                j += 2
            }
        }
        return ({ kind: kind, params: params, next: j })
    }
    function codeToEntry(code) {
        const parts = String(code).trim().toLowerCase().split("+")
        if (parts.length === 1) return layerFromCode(parts[0])
        const ls = []
        for (const p of parts) {
            const e = layerFromCode(p)
            if (e === null) return null
            ls.push(typeof e === "string" ? ({ colour: e }) : e)
        }
        // the halo parsed onto the last layer is the stack's: hoist it
        const out = ({ layers: ls })
        const last = ls[ls.length - 1]
        if (last.effect !== undefined) { out.effect = last.effect; delete last.effect }
        return out
    }
    function layerFromCode(code) {
        let c = String(code).trim().toLowerCase()
        if (c.length === 0 || c[0] !== "#") return null
        const isHex = (x) => /^[0-9a-f]+$/.test(x)
        let n = 7
        if (c.length >= 9 && isHex(c.substr(1, 8)) && !"scpbeotnmwfk".includes(c[7])) n = 9
        if (c.length < n || !isHex(c.substr(1, n - 1))) return null
        const colour = c.substr(0, n)
        if (c.length === n) return colour
        const o = ({ colour: colour })
        const sgn = (b) => Number((b / 255 * 2 - 1).toFixed(2))
        // enough characters left, and all of them hex: a segment cut short is
        // read as the end of what this build understands, not as NaN levers
        const has = (j, len) => c.length >= j + len && isHex(c.substr(j, len))
        let i = n
        const contrastAt = (j) => ({ hue: sgn(byteOf(c, j)), lum: sgn(byteOf(c, j + 2)), sat: sgn(byteOf(c, j + 4)),
                                     opacity: Number((byteOf(c, j + 6) / 255).toFixed(2)) })
        while (i < c.length) {
            const tag = c[i]
            if (tag === "c") { if (!has(i + 1, 8)) break; o.source = "adaptive"; o.amounts = contrastAt(i + 1); i += 9 }
            else if (tag === "s" || tag === "p" || tag === "f") {
                if (!has(i + 1, tag === "s" ? 8 : tag === "f" ? 2 : 10)) break
                const f = parseFill(c, i)
                if (f.kind) { o.source = f.kind; o.params = f.params }
                i = f.next
            }
            else if (tag === "b") { if (!has(i + 1, 1)) break; o.blend = blendCodes[parseInt(c[i + 1], 16)] || ""; if (!o.blend) delete o.blend; i += 2 }
            else if (tag === "n") { if (!has(i + 1, 2)) break; o.blend = blendCodes[byteOf(c, i + 1)] || ""; if (!o.blend) delete o.blend; i += 3 }
            else if (tag === "o") { if (!has(i + 1, 2)) break; o.opacity = Number((byteOf(c, i + 1) / 255).toFixed(2)); i += 3 }
            else if (tag === "t") { if (!has(i + 1, 2)) break; o.phase = Number((byteOf(c, i + 1) / 255).toFixed(2)); i += 3 }
            else if (tag === "w") {
                if (!has(i + 1, 1)) break
                o.space = fillSpaces[parseInt(c[i + 1], 16)] || "window"
                if (o.space === "window") delete o.space
                i += 2
            }
            else if (tag === "m") {
                if (!has(i + 1, 3)) break
                o.mask = maskModes[parseInt(c[i + 1], 16)] || "all"
                if (o.mask === "all") delete o.mask
                else o.maskDist = Number((byteOf(c, i + 2) / 255 * 31.5).toFixed(1))
                i += 4
            }
            // how far the band's edge fades; written only when it does
            else if (tag === "q") {
                if (!has(i + 1, 2)) break
                o.maskSoft = Number((byteOf(c, i + 1) / 255 * 31.5).toFixed(1))
                i += 3
            }
            else if (tag === "e") {
                if (!has(i + 1, 11)) break
                const kind = ["off", "glow", "outline", "shadow"][parseInt(c[i + 1], 16)] || "off"
                const e = ({ kind: kind, size: Number((byteOf(c, i + 2) / 255 * 8).toFixed(1)), soft: Number((byteOf(c, i + 4) / 255).toFixed(2)),
                             dx: Math.round(byteOf(c, i + 6) / 255 * 16 - 8), dy: Math.round(byteOf(c, i + 8) / 255 * 16 - 8),
                             opacity: Number((byteOf(c, i + 10) / 255).toFixed(2)) })
                i += 12
                if (c[i] === "c") { if (!has(i + 1, 8)) break; e.colour = ({ source: "adaptive", amounts: contrastAt(i + 1) }); i += 9 }
                else {
                    if (!has(i, 6)) break
                    e.colour = "#" + c.substr(i, 6); i += 6
                    if (c[i] === "s" || c[i] === "p") {   // the halo's colour is a fill
                        const f = parseFill(c, i)
                        if (f.kind) e.colour = ({ colour: e.colour, source: f.kind, params: f.params })
                        i = f.next
                    }
                }
                o.effect = e
            }
            else break   // a tag from a newer melo: keep what came before it
        }
        return Object.keys(o).length === 1 ? colour : o
    }
    // Roles added after themes were written follow a parent until a theme gives
    // them their own. Editors must start a new entry from the inherited entry, not the
    // flat colour, or the fill or contrast is lost.
    readonly property var entryParents: ({ textOverArt: "text", control: "textSoft", controlOff: "borderStrong", controlHover: "text",
                                           title: "chrome", skeleton: "button", input: "button", buttonHover: "hover", buttonPress: "hover", closeFace: "button", closeFaceHover: "buttonHover", titleButton: "button", titleButtonHover: "buttonHover", titleButtonActive: "buttonActive", titleButtonBorder: "border", titleButtonBorderHover: "borderStrong", titleButtonPress: "buttonPress", closeFacePress: "buttonPress", close: "textDim", closeHover: "text", titleGlyph: "textDim", titleGlyphHover: "text", titleGlyphActive: "textOnActive", textOnTitle: "textDim", textOnSelected: "text", textOnActive: "textOnSelected", windowBorder: "borderStrong", windowBorderInner: "windowBorder", windowBorderOuter: "windowBorder", panelHeader: "panel", highlight: "accent",
                                           scrubber: "accent", graph: "accent", tabLine: "accent",
                                           sliderTrack: "button", sliderFill: "accent", toggleOff: "button", toggleOn: "accent",
                                           buttonActive: "selected", cardSelected: "selected", scrubberTrack: "button" })
    // Which roles came from a swatch. `from` is inert provenance — an entry
    // whose stamp names nothing still renders — and rolesFrom is what reads
    // it, so setThemeSwatch can rewrite every role stamped with a swatch.
    // an entry as a role holds it: the value, and which swatch it uses
    function stamped(entry, id) {
        const o = (entry !== null && typeof entry === "object") ? Object.assign({}, entry) : ({ colour: String(entry) })
        o.from = String(id)
        return o
    }
    // A theme swatch is written, and every role using it with it — the one
    // place that happens, whichever window asked. An id the theme does not
    // hold yet is added under the name given.
    function setThemeSwatch(id, name, entry) {
        if (typeof ThemeBackend === "undefined") return
        const have = ThemeBackend.themeSwatches(), list = []
        let found = false
        if (isList(have)) for (let i = 0; i < have.length; ++i) {
            if (have[i] && String(have[i].id) === String(id)) { list.push({ id: have[i].id, name: have[i].name, entry: entry }); found = true }
            else list.push(have[i])
        }
        if (!found) list.push({ id: String(id), name: String(name), entry: entry })
        ThemeBackend.setThemeSwatches(list)
        const roles = rolesFrom(id)
        for (let i = 0; i < roles.length; ++i) ThemeBackend.setPaletteColor(roles[i], stamped(entry, id))
    }
    function rolesFrom(swatchId) {
        const out = []
        if (!swatchId) return out
        for (const k in p) {
            const v = p[k]
            if (v !== null && typeof v === "object" && v.from !== undefined
                && String(v.from) === String(swatchId)) out.push(k)
        }
        return out
    }

    // ---- the palette as the colours it is made of ---------------------------
    // Simple mode edits colours, not roles: these find every literal colour (role,
    // stack layer, fill stop, ink halo) and group equal values. Groups are computed
    // each time and never stored, so editing one writes colours and stamps nothing.

    // A literal, or nothing. Qt's own order: a palette's 8-digit hex is
    // #AARRGGBB (applyPalette writes system colours with HexArgb), and a
    // sentinel — "systemaccent", "system:window" — is not a literal at all
    // and must be left where it is rather than folded into a group.
    function litColour(raw) {
        if (typeof raw !== "string") return null
        const s = raw.trim()
        if (!/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(s)) return null
        return Qt.color(s)
    }
    // colour ⇄ hex, in Qt's order — #AARRGGBB when there is an alpha — the
    // order the entry code, the palette and the picker's box all use
    function hexOf(c) { return c.toString() }
    function colourFromHex(t) {
        if (!/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(String(t))) return null
        return Qt.color(t)
    }
    function colourPlaces(pal) {
        const out = []
        const at = (role, path, raw) => {
            const c = litColour(raw)
            if (c !== null) out.push({ role: role, path: path, hex: hexOf(c) })
        }
        const one = (role, path, e) => {   // one layer, or a whole flat entry
            if (typeof e === "string") { at(role, path, e); return }
            if (e === null || typeof e !== "object") return
            at(role, path.concat(["colour"]), e.colour)
            if (e.params !== null && typeof e.params === "object" && isList(e.params.colours))
                for (let j = 0; j < e.params.colours.length; ++j)
                    at(role, path.concat(["params", "colours", j]), e.params.colours[j])
        }
        for (const role in pal) {
            const v = pal[role]
            // A STACK'S OWN colour/params ARE DEAD: layersOf reads the layers
            // and nothing else, so counting the entry's leftover fields would
            // report places no renderer ever looks at.
            if (v !== null && typeof v === "object" && isList(v.layers))
                for (let i = 0; i < v.layers.length; ++i) one(role, ["layers", i], v.layers[i])
            else one(role, [], v)
            // an ink's halo is a colour of the ENTRY, not of a layer
            if (v !== null && typeof v === "object" && v.effect !== null && typeof v.effect === "object")
                at(role, ["effect", "colour"], v.effect.colour)
        }
        return out
    }
    // Groups, most-used first: exact values, then near-equals folded into the
    // commonest (`tolerance` per channel 0..255, default 6). Alpha is not folded.
    // Greedy against the group colour, not transitive, so a ramp stays a ramp.
    function colourGroups(pal, tolerance) {
        const tol = (tolerance === undefined || tolerance === null || isNaN(parseFloat(tolerance)))
                    ? 6 : Math.max(0, parseFloat(tolerance))
        const places = colourPlaces(pal), exact = ({}), order = []
        for (let i = 0; i < places.length; ++i) {
            const h = places[i].hex
            if (exact[h] === undefined) { exact[h] = ({ colour: h, count: 0, places: [] }); order.push(h) }
            exact[h].count++
            exact[h].places.push({ role: places[i].role, path: places[i].path })
        }
        // ties broken by hex, so the answer does not depend on the order the
        // palette happens to be written in
        const bycount = (a, b) => b.count - a.count || (a.colour < b.colour ? -1 : a.colour > b.colour ? 1 : 0)
        const ex = order.map(h => exact[h]).sort(bycount)
        const rgb = (h) => [parseInt(h.substr(1, 2), 16), parseInt(h.substr(3, 2), 16), parseInt(h.substr(5, 2), 16)]
        const alpha = (h) => h.length === 9 ? h.substr(7, 2).toLowerCase() : "ff"
        const out = []
        for (let i = 0; i < ex.length; ++i) {
            const g = ex[i], a = rgb(g.colour)
            let host = null
            for (let j = 0; j < out.length && host === null; ++j) {
                const b = rgb(out[j].colour)
                if (alpha(out[j].colour) === alpha(g.colour)
                    && Math.abs(a[0] - b[0]) <= tol && Math.abs(a[1] - b[1]) <= tol
                    && Math.abs(a[2] - b[2]) <= tol) host = out[j]
            }
            if (host === null) out.push({ colour: g.colour, count: g.count, places: g.places })
            else { host.count += g.count; host.places = host.places.concat(g.places) }
        }
        return out.sort(bycount)
    }
    // A palette out of c++ IS QVariantMap/QVariantList — array-like, and not
    // ours to write into. A recoloured palette is built as plain JS.
    function cloneValue(v) {
        if (v === null || v === undefined || typeof v !== "object") return v
        if (isList(v)) { const a = []; for (let i = 0; i < v.length; ++i) a.push(cloneValue(v[i])); return a }
        const o = {}
        for (const k in v) o[k] = cloneValue(v[k])
        return o
    }
    // Writes `toColour` (a colour, or a string in Qt's order) to every place the
    // group lists. Object places keep other fields; `from` stamps are left for the
    // swatch section.
    function recolour(pal, fromGroup, toColour) {
        const lit = litColour(toColour)
        const to = String(lit !== null ? lit : toColour)
        const out = {}
        for (const k in pal) out[k] = pal[k]
        const places = (fromGroup !== null && typeof fromGroup === "object" && isList(fromGroup.places))
                       ? fromGroup.places : []
        for (let i = 0; i < places.length; ++i) {
            const role = String(places[i].role), path = places[i].path
            if (!isList(path) || path.length === 0) { out[role] = to; continue }
            if (out[role] === pal[role]) out[role] = cloneValue(pal[role])   // once per role
            let cur = out[role]
            for (let j = 0; j < path.length - 1 && cur !== null && cur !== undefined; ++j) cur = cur[path[j]]
            if (cur !== null && cur !== undefined && typeof cur === "object") cur[path[path.length - 1]] = to
        }
        return out
    }
    function entryOf(key) {
        if (p[key] !== undefined) return p[key]
        const parent = entryParents[key]
        return parent !== undefined ? p[parent] : undefined
    }
    // what a source is called on screen: "adaptive" is the file's word, contrast the user's
    // an entry in a few words: its kinds bottom-up, a plain colour by its hex
    function entryLabel(v) {
        return layersOf(v).map(l => {
            const src = sourceOf(l)
            return src === "colour" ? colorOf(l, "#000000").toString().slice(0, 7) : sourceName(src)
        }).join(" + ")
    }
    function sourceName(source) {
        return source === "adaptive" ? "contrast" : isFilter(source) ? filterName(source)
             : isStyled(source) ? fillName(source) : source
    }
    // reads the glyph coverage itself (an edge, a level), so a swatch of it says nothing
    function fillImage(kind) { const f = fillOf(kind); return f ? f.image === true : false }
    readonly property var imageFits: ["tile", "cover", "contain", "stretch", "native", "9-slice"]
    readonly property var imageAnchors: ["top left", "top", "top right", "left", "centre", "right", "bottom left", "bottom", "bottom right"]
    function imageOption(params, name) {
        const option = fillOptionTables.image.find(o => o.name === name)
        if (!option) return 0
        const own = params && params.own ? params.own : (params || {})
        const raw = own[name], n = raw === null ? NaN : parseFloat(raw)
        const value = isFinite(n) ? n : option.value
        return Math.max(option.from, Math.min(option.to, option.step >= 1 ? Math.round(value) : value))
    }
    function fillMoves(kind, params) {
        // A fitted picture is pinned; only tiles scroll. Retain its saved
        // speed so switching back to tiles restores the old motion.
        return params.speed !== 0 && (kind !== "image" || imageOption(params, "fit") === 0)
    }
    function sourceOf(raw) {
        const v = base(raw)
        if (v === null || typeof v !== "object") return "colour"
        if (v.source === "adaptive") return "adaptive"
        if (["neon", "liquid"].indexOf(v.source) >= 0) return "colour"   // written as a source once
        // The two retired materials use their replacements, including in
        // saved theme JSON. Their numeric slots (and opal/nebula's) stay put.
        const source = ({ caustics: "agate", silk: "mercury" })[v.source] || v.source
        if (isFilter(source)) return String(source)
        return isStyled(source) ? String(source) : "colour"
    }
    // A styled fill's levers: speed (0 is still), scale, angle in degrees,
    // and the palette stops for kinds that take them.
    readonly property var styledDefaults: ({ speed: 0.3, scale: 1, angle: 0, colours: [], src: "" })
    // a list however it arrived — a JS array, or a QVariantList from C++,
    // which is array-like without being an Array
    function listOf(x) {
        const out = []
        if (x && typeof x.length === "number") for (let i = 0; i < x.length; ++i) out.push(String(x[i]))
        return out
    }
    function styledOf(raw) {
        const v = base(raw)
        const a = (v !== null && typeof v === "object" && v.params && typeof v.params === "object") ? v.params : ({})
        const n = (x, d) => (x === undefined || x === null || isNaN(parseFloat(x))) ? d : parseFloat(x)
        const d = styledDefaults
        return ({ speed: Math.max(-1, Math.min(1, n(a.speed, d.speed))),   // negative runs backwards
                  scale: Math.max(0.1, Math.min(8, n(a.scale, d.scale))),
                  angle: Math.max(0, Math.min(360, n(a.angle, d.angle))),
                  // the palette: a list, or the colour2 / colour3 pair themes wrote before it was one
                  colours: listOf(a.colours).length ? listOf(a.colours)
                         : [a.colour2, a.colour3].filter(x => x !== undefined && x !== null).map(String),
                  src: a.src !== undefined ? String(a.src) : d.src,
                  // Unknown `params` keys ride along so a newer melo's options survive an older
                  // picker. Params already normalised by layersOf carry `own`, which is merged, not
                  // nested as own.own.
                  own: (function () {
                      const known = ["speed", "scale", "angle", "colours", "src", "colour2", "colour3", "own"]
                      const o = {}
                      if (a.own && typeof a.own === "object") for (const k in a.own) o[k] = a.own[k]
                      for (const k in a) if (known.indexOf(k) < 0) o[k] = a[k]
                      return o
                  })() })
    }
    // An entry as a list of layers, bottom-up. An entry without layers is one
    // layer; per-layer opacity and blend default to the entry's, so flat entries keep
    // their meaning.
    function layersOf(v) {
        const one = (e) => ({
            source: sourceOf(e), colour: colorOf(e, "#ffffff"), params: styledOf(e),
            blend: blendOf(e), amounts: adaptiveOf(e),
            opacity: (e !== null && typeof e === "object" && e.opacity !== undefined)
                     ? Math.max(0, Math.min(1, parseFloat(e.opacity))) : 1,
            // MASK MODE: the whole shape, a band within `maskDist` px of its
            // edge, or everything beyond that band. The distance field is
            // built for the shape-aware kinds anyway, so a layer of any kind
            // can be confined to a rim or an interior.
            mask: (e !== null && typeof e === "object" && maskModes.indexOf(String(e.mask)) > 0) ? String(e.mask) : "all",
            maskDist: (e !== null && typeof e === "object" && e.maskDist !== undefined)
                      ? Math.max(0, Math.min(31.5, parseFloat(e.maskDist) || 0)) : 3,
            // ...and how far its edge fades: 0 is a one-pixel edge
            maskSoft: (e !== null && typeof e === "object" && e.maskSoft !== undefined)
                      ? Math.max(0, Math.min(31.5, parseFloat(e.maskSoft) || 0)) : 0,
            // Where this layer is in the cycle. Two layers of one kind draw
            // the same picture at speed 0 and move together above it; this is
            // how one of them is somewhere else. 0..1 is a full turn.
            phase: (e !== null && typeof e === "object" && e.phase !== undefined)
                   ? Math.max(0, Math.min(1, parseFloat(e.phase) || 0)) : 0,
            space: (e !== null && typeof e === "object" && fillSpaces.indexOf(String(e.space)) > 0)
                   ? String(e.space) : "window"
        })
        if (v === null || typeof v !== "object" || !isList(v.layers)) return [one(v)]
        // A layer may be a bare colour string, as a plain colour is written
        // everywhere else in this format; one() takes it like any other layer.
        const l = []
        for (let i = 0; i < v.layers.length; ++i)
            if (v.layers[i] !== null && v.layers[i] !== undefined) l.push(one(v.layers[i]))
        return l.length ? l : [one(v)]
    }
    // AND BACK. A stack of one is written flat — the shape every existing theme
    // has — so a file only grows a `layers` list once there is a second layer
    // in it. Nothing churns for entries nobody has layered.
    function entryFromLayers(layers, base) {
        const flat = (L) => {
            const e = {}
            if (base !== undefined && base !== null && typeof base === "object")
                for (const k in base) if (k !== "layers") e[k] = base[k]
            e.colour = L.colour; e.source = L.source
            const p = {}
            p.speed = L.params.speed; p.scale = L.params.scale; p.angle = L.params.angle
            if (L.params.colours && L.params.colours.length) p.colours = L.params.colours
            if (L.params.src) p.src = L.params.src
            for (const k in (L.params.own || {})) p[k] = L.params.own[k]
            e.params = p
            if (L.blend && L.blend.length) e.blend = L.blend; else delete e.blend
            if (L.opacity !== undefined && L.opacity < 1) e.opacity = L.opacity; else delete e.opacity
            if (L.mask && L.mask !== "all") {
                e.mask = L.mask; e.maskDist = L.maskDist
                if (L.maskSoft > 0) e.maskSoft = L.maskSoft; else delete e.maskSoft
            } else { delete e.mask; delete e.maskDist; delete e.maskSoft }
            if (L.phase > 0) e.phase = L.phase; else delete e.phase
            if (L.space && L.space !== "window") e.space = L.space; else delete e.space
            return e
        }
        if (!isList(layers) || layers.length === 0) return base
        if (layers.length === 1) return flat(layers[0])
        return ({ layers: layers.map(flat) })
    }
    // Does any layer of this move. `sourceOf` and `styledOf` answer for the
    // bottom layer, which is what everything that takes one value needs —
    // but a still colour under a moving fill is a moving entry, and asking
    // only the bottom would leave a theme animated in an upper layer frozen.
    function entryMoves(v) {
        // A flat colour moves nothing, and answering that needed no stack
        // built. anyAnimated asks this of every role and every ink effect, and
        // layersOf() materialises the whole entry to do it — for a palette of
        // plain colours, which is most of them, that is pure garbage.
        if (!isList(v !== null && typeof v === "object" ? v.layers : null)
            && !isStyled(sourceOf(v))) return false
        const ls = layersOf(v)
        // ...and a layer nobody can see is not one: an animation under an
        // opaque cover would keep the whole app repainting at sixty frames a
        // second for a picture that never reaches the screen.
        for (let i = coveredBelow(ls); i < ls.length; ++i)
            if (isStyled(ls[i].source) && fillMoves(ls[i].source, ls[i].params)) return true
        return false
    }
    // Index of the topmost layer that fully covers those below (a full-alpha plain
    // colour; all layers share one mask), or 0. Blends above read the cover, so this
    // is exact. StyledFill draws from here up.
    function coveredBelow(ls) {
        for (let i = ls.length - 1; i > 0; --i) {
            const L = ls[i]
            if (sourceOf(L) !== "colour") continue
            if (String(L.mask === undefined ? "all" : L.mask) !== "all") continue
            if (String(L.blend || "").length > 0) continue
            if ((L.opacity !== undefined ? L.opacity : 1) * colorOf(L, "#ffffff").a < 1) continue
            return i
        }
        return 0
    }
    // one clock for every moving fill, ticking only while one is on screen
    readonly property bool anyAnimated: {
        for (const k in p) if (entryMoves(p[k])) return true
        // an ink's halo colour moves too
        for (let i = 0; i < inkRoles.length; ++i)
            if (entryMoves(inkRole(inkRoles[i]).effect.colour)) return true
        return false
    }
    // seconds, advanced by the animation driver — one step per rendered
    // frame, whatever the display's rate. A timer gives 30 uneven steps a
    // second, which reads as stutter.
    property real clock: 0
    // Bound to Main's drag flag: frames rendered during a move or resize lag the
    // compositor's configure and get stretched. Every moving fill and the picker's
    // live tiles pause on it.
    property bool held: false
    // a picker showing moving previews wants the clock even in a still theme
    property int previewing: 0
    // a few times a second, for the things that need refreshing but not
    // every frame (where a fill sits in the window)
    property int slowTick: 0
    // The tick runs only if some fill reads it (or the picker previews); flat
    // palettes would wake the JS engine three times a second for nothing. Not gated
    // on the window: `held` covers drags, and an unheard tick is only a property write.
    readonly property bool anyPatterned: {
        for (const k in p) if (anyStyled(p[k])) return true
        // an ink's halo carries its own entry
        for (let i = 0; i < inkRoles.length; ++i)
            if (anyStyled(inkRole(inkRoles[i]).effect.colour)) return true
        return false
    }
    // ...and while anything adapts. An adaptive layer is not a styled kind,
    // and HueLum re-maps where it sits on this tick, as a fill does.
    readonly property Timer slowTicker: Timer { interval: 300; repeat: true
                                               running: Theme.anyPatterned || Theme.previewing > 0
                                                        || Theme.adaptiveLive > 0
                                               onTriggered: Theme.slowTick += 1 }
    // A 1x1 opaque white PNG for fill samplers with nothing to bind (mask, field,
    // picture); the scene graph keeps one texture per source per window.
    readonly property string blankTex: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4////fwAJ+wP99djxmgAAAABJRU5ErkJggg=="
    readonly property Connections layoutWatch: Connections {
        target: typeof ThemeBackend !== "undefined" ? ThemeBackend : null
        function onThemesChanged() { Theme.layoutGen++ }
    }
    // Paused while held, not stopped: a stopped animation starts again from
    // `from`, so every fill in the app would jump back to its first frame
    // after a resize. Pausing keeps the clock where the drag found it.
    readonly property NumberAnimation ticker: NumberAnimation {
        target: Theme; property: "clock"; from: 0; to: 86400; duration: 86400000
        running: Theme.anyAnimated || Theme.previewing > 0
        paused: running && Theme.held
    }
    // hue, luminosity, saturation (-1..1) and strength (0..1) as a vector4d.
    // Defaults to a plain inversion at full strength.
    function adaptiveOf(raw) {
        const v = base(raw)
        const a = (v !== null && typeof v === "object" && v.amounts) ? v.amounts : ({})
        const n = (x, d) => (x === undefined || isNaN(parseFloat(x))) ? d : parseFloat(x)
        return Qt.vector4d(Math.max(-1, Math.min(1, n(a.hue, 0))),
                           Math.max(-1, Math.min(1, n(a.lum, -1))),
                           Math.max(-1, Math.min(1, n(a.sat, 0))),
                           Math.max(0, Math.min(1, n(a.opacity, 1))))
    }

    // An ink's halo, drawn beneath its words; every field has a default. ScrollText
    // renders it as a dilation or blur; a plain Text maps it to Qt's 1px style.
    // kind: off | glow | outline | shadow; size and dx/dy in logical pixels.
    readonly property var effectKinds: ["off", "glow", "outline", "shadow"]
    readonly property var effectOff: ({ kind: "off", size: 1, soft: 0, dx: 0, dy: 1,
                                        colour: "#000000", opacity: 0.75 })
    function effectOf(v, fallback) {
        const base = fallback !== undefined ? fallback : effectOff
        const e = (v !== null && typeof v === "object" && v.effect && typeof v.effect === "object")
                  ? v.effect : ({})
        const n = (x, d) => (x === undefined || x === null || isNaN(parseFloat(x))) ? d : parseFloat(x)
        const kind = effectKinds.indexOf(e.kind) >= 0 ? e.kind : base.kind
        return ({ kind: kind,
                  size: Math.max(0, Math.min(8, n(e.size, base.size))),
                  soft: Math.max(0, Math.min(1, n(e.soft, base.soft))),
                  dx: Math.max(-8, Math.min(8, n(e.dx, base.dx))),
                  dy: Math.max(-8, Math.min(8, n(e.dy, base.dy))),
                  colour: e.colour !== undefined ? e.colour : base.colour,
                  opacity: Math.max(0, Math.min(1, n(e.opacity, base.opacity))) })
    }
    // the effect's colour, resolved: a colour, or adaptive against the ink
    // itself — a halo is there to contrast with its own words, and the default
    // amounts are their inverse
    function effectColour(effect, inkColour) {
        const c = effect.colour
        if (sourceOf(c) === "adaptive") return adapt(inkColour, adaptiveOf(c))
        return colorOf(c, "#000000")
    }
    // Qt's own style, for a plain Text: the nearest 1px thing to the effect
    function effectStyle(effect) {
        return effect.kind === "off" ? Text.Normal
             : effect.kind === "outline" || effect.kind === "glow" ? Text.Outline : Text.Raised
    }

    // ---- roles --------------------------------------------------------------
    readonly property var roleFallback: ({
        // The page is nothing unless a theme says otherwise: it lies over the
        // window, so following the window would paint a glass theme twice
        window: "#0f0f0f", page: "#00000000", chrome: "#151515", title: "#151515", skeleton: "#333333", panelHeader: "#151515", player: "#1a1a1a", panel: "#151515",
        dialog: "#1a1a1a", menu: "#222222", card: "#1a1a1a", button: "#222222",
        hover: "#333333", selected: "#333333", toast: "#222222",
        scrollbar: "#333333", tooltip: "#222222", scrubber: "#cc3333", graph: "#cc3333", tabLine: "#cc3333", highlight: "#cc3333",
        // the knobs follow nothing, so white is where a theme that names
        // neither leaves them
        sliderKnob: "#ffffff", toggleKnob: "#ffffff", scrubberKnob: "#ffffff"
    })
    // Stable until its content changes. `ts` is a new map on every settings
    // write, so an object read straight out of it would be a new object every
    // time, and every role — so every surface — would re-resolve on a change
    // to the window radius. A string only notifies when it differs.
    readonly property string opacityKey: JSON.stringify(ts.opacity !== undefined ? ts.opacity : ({}))
    readonly property var opacityMap: JSON.parse(opacityKey)
    // the master: multiplies every non-floating surface
    readonly property real opacityScale: ts.opacityScale !== undefined ? ts.opacityScale : 1

    // An entry as one colour, its layer opacity folded into alpha, for everything
    // that cannot draw layers (colorOf alone would draw a 50% layer at full). The
    // layer renderer never reads this, so opacity is not applied twice.
    function flatColour(v, fb) {
        const c = colorOf(v, fb), b = base(v)
        const op = (b !== null && typeof b === "object" && b.opacity !== undefined)
                 ? Math.max(0, Math.min(1, parseFloat(b.opacity))) : 1
        return op < 1 ? Qt.rgba(c.r, c.g, c.b, c.a * op) : c
    }
    // PURE, so tests can hand it a palette, an opacity map and a scale
    // instead of a running app.
    function roleFrom(pal, opacities, scale, name) {
        // A role added after themes were written follows an older one unless
        // a theme gives it its own — entry and opacity both — so every theme
        // from before it existed looks exactly as it did: the title bar
        // follows the header, the loading bars follow the field.
        const parentRole = ({ title: "chrome", skeleton: "button", windowBorder: "borderStrong",
                              windowBorderInner: "windowBorder", windowBorderOuter: "windowBorder", panelHeader: "panel", scrubber: "accent", graph: "accent", tabLine: "accent", highlight: "accent",
                              input: "button", buttonHover: "hover", buttonPress: "hover", closeFace: "button", closeFaceHover: "buttonHover",
                              titleButton: "button", titleButtonHover: "buttonHover", titleButtonActive: "buttonActive", titleButtonBorder: "border", titleButtonBorderHover: "borderStrong", titleButtonPress: "buttonPress", closeFacePress: "buttonPress",
                              // A control's parts follow the control: a track is a
                              // button face, a fill is the accent, an active button is
                              // the selected surface.
                              sliderTrack: "button", sliderFill: "accent", toggleOff: "button", toggleOn: "accent",
                              buttonActive: "selected",
                              // the seek bar's groove, wherever a layout puts it
                              scrubberTrack: "button",
                              // A scrollbar is not a volume slider: drawn with the
                              // slider's own parts, a volume thumb cut as a small
                              // capsule would be stretched the height of a page.
                              // These follow the slider's until a theme cuts its own.
                              scrollbarTrack: "sliderTrack", scrollbarThumb: "sliderKnob",
                              // ...and the volume rail's, for the same reason
                              volumeTrack: "sliderTrack", volumeFill: "sliderFill", volumeKnob: "sliderKnob",
                              // the playing card, as the playing row is
                              cardSelected: "selected" })[name]
        const inherit = parentRole !== undefined && pal[name] === undefined
        const v = inherit ? pal[parentRole] : pal[name]
        if (inherit && opacities[name] === undefined && opacities[parentRole] !== undefined) {
            const o = Object.assign({}, opacities); o[name] = opacities[parentRole]; opacities = o
        }
        // A role's own opacity is absolute, so a header can be solid under a
        // glass master. The master is what a role without one gets, and the settings' master slider writes
        // every surface at once rather than sitting on top of them.
        const hasOwn = opacities[name] !== undefined
        const own = hasOwn ? opacities[name] : 1
        const floating = floatingRoles.indexOf(name) >= 0
        // a colour that is not a surface — accent, border, danger — is never
        // scaled by the master either
        const notSurface = surfaceRoles.indexOf(name) < 0
        return ({
            // a role that follows another falls back as that one does
            colour: flatColour(v, roleFallback[name] || roleFallback[parentRole] || "#000000"),
            opacity: hasOwn ? own : (floating || notSurface ? 1 : scale),
            source: sourceOf(v),
            blend: blendOf(v),
            amounts: adaptiveOf(v),
            params: styledOf(v),
            // The whole stack, for what can draw one. The four fields above
            // are the bottom layer of it, which is what everything that takes
            // a single colour gets.
            layers: layersOf(v),
        })
    }
    // ---- the memo -----------------------------------------------------------
    // Within a generation a name resolves once; across generations an unchanged role
    // keeps its object, so a palette write does not re-run every Surface, InkText,
    // ScrollText and Icon. State is mutated in place: reassigning a property would
    // notify and re-run the bindings the memo keeps still.
    readonly property var memo: ({ p: null, opKey: "", scale: -1, rGen: -1, gen: 0, role: ({}), ink: ({}) })
    // p is a new object on every ThemeBackend.palette write, so identity is the
    // generation in the running app; `gen` below is bumped by hand for a test
    // that mutates Theme.p in place.
    property int roleGen: 0
    onPChanged: ++roleGen
    onTsChanged: ++roleGen
    // for a caller that mutates the palette without a signal
    function invalidateRoles() { ++roleGen }
    // Compares the parts rather than building a key: this runs on every role() and
    // inkRole() call, and a fresh string each time feeds GUI-thread GC.
    function memoGen() {
        const m = memo
        if (m.p !== p || m.opKey !== opacityKey || m.scale !== opacityScale || m.rGen !== roleGen) {
            m.p = p; m.opKey = opacityKey; m.scale = opacityScale; m.rGen = roleGen
            ++m.gen
        }
        return m.gen
    }
    // A resolved role as text, so "unchanged" is a string compare. Colours and
    // vectors carry their own stable toString; a plain object does not, and is
    // walked by sorted key.
    function sigOf(v) {
        if (v === null || v === undefined) return ""
        if (typeof v !== "object") return String(v)
        if (isList(v)) {
            let s = "["
            for (let i = 0; i < v.length; ++i) s += sigOf(v[i]) + ","
            return s + "]"
        }
        // C++ maps stringify as "[object V4ReferenceObject]" and must be walked too;
        // returning the constant signs every nested entry alike, leaving the memo stale.
        const t = String(v)
        if (t !== "[object Object]" && t !== "[object V4ReferenceObject]") return t
        const ks = Object.keys(v).sort()
        let s = "{"
        for (let i = 0; i < ks.length; ++i) s += ks[i] + "=" + sigOf(v[ks[i]]) + ";"
        return s + "}"
    }
    function memoised(cache, name, gen, value) {
        const e = cache[name]
        if (e !== undefined && e.gen === gen) return e.val
        const v = value()
        const sig = sigOf(v)
        if (e !== undefined && e.sig === sig) { e.gen = gen; return e.val }
        cache[name] = ({ gen: gen, sig: sig, val: v })
        return v
    }
    // The hit path allocates nothing: a `() => roleFrom(...)` closure per call
    // would mean thousands a second during a resize, and GC drops frames.
    function role(name) {
        const g = memoGen(), e = memo.role[name]
        if (e !== undefined && e.gen === g) return e.val
        return memoised(memo.role, name, g, () => roleFrom(p, opacityMap, opacityScale, name))
    }
    // Is there anything to blur behind. The compositor's effect only shows
    // where the surface is see-through, so every glass decision asks this
    // rather than asking a setting: a role's own opacity, or the palette
    // colour's own alpha, makes a surface see-through with the master at 1.
    function translucent(name) { return roleColour(name).a < 0.999 }

    // An entry resolved the way a role is, for a colour that is not in the
    // palette at all — a frame band's own. The same four fields every
    // single-colour consumer reads, and the stack for what can draw one.
    function roleOfEntry(v) {
        return ({ colour: flatColour(v, "#000000"), opacity: 1, source: sourceOf(v),
                  blend: blendOf(v), amounts: adaptiveOf(v), params: styledOf(v),
                  layers: layersOf(v) })
    }
    // the colour with its opacity folded in: what a surface paints when it is
    // not blending
    function roleColour(name) {
        const r = role(name)
        return Qt.rgba(r.colour.r, r.colour.g, r.colour.b, r.colour.a * r.opacity)
    }

    // the surfaces, as colours
    readonly property color window: roleColour("window")
    readonly property color page: roleColour("page")
    // whether a page is drawn at all: a colour, or a fill with none
    readonly property bool hasPage: page.a > 0.001 || layered(entryOf("page"))
    readonly property color chrome: roleColour("chrome")
    readonly property color title: roleColour("title")
    readonly property color skeleton: roleColour("skeleton")
    readonly property color panelHeader: roleColour("panelHeader")
    readonly property color button: roleColour("button")
    readonly property color buttonHover: roleColour("buttonHover")
    readonly property color buttonPress: roleColour("buttonPress")
    readonly property color closeFace: roleColour("closeFace")
    readonly property color closeFaceHover: roleColour("closeFaceHover")
    readonly property color titleButton: roleColour("titleButton")
    readonly property color titleButtonHover: roleColour("titleButtonHover")
    readonly property color titleButtonActive: roleColour("titleButtonActive")
    readonly property color titleButtonPress: roleColour("titleButtonPress")
    readonly property color closeFacePress: roleColour("closeFacePress")
    readonly property color titleButtonBorder: roleColour("titleButtonBorder")
    readonly property color titleButtonBorderHover: roleColour("titleButtonBorderHover")
    readonly property color buttonActive: roleColour("buttonActive")
    readonly property color scrubberTrack: roleColour("scrubberTrack")
    // A CONTROL'S PARTS. The track and the toggle's off face are surfaces and
    // take the master opacity as the button does; the fill and the knobs are
    // marks — accent, white — and do not, so they are colours, like accent.
    readonly property color sliderTrack: roleColour("sliderTrack")
    readonly property color sliderFill: roleColour("sliderFill")
    readonly property color sliderKnob: roleColour("sliderKnob")
    readonly property color scrubberKnob: roleColour("scrubberKnob")
    readonly property color toggleOff: roleColour("toggleOff")
    readonly property color toggleOn: roleColour("toggleOn")
    readonly property color toggleKnob: roleColour("toggleKnob")
    // `player`, not `bar`: Theme.bar() is the player bar's SIZE function
    readonly property color player: roleColour("player")
    readonly property color panel: roleColour("panel")
    readonly property color dialog: roleColour("dialog")
    readonly property color menu: roleColour("menu")
    readonly property color card: roleColour("card")
    readonly property color input: roleColour("input")
    readonly property color hover: roleColour("hover")
    readonly property color selected: roleColour("selected")
    readonly property color cardSelected: roleColour("cardSelected")
    readonly property color toast: roleColour("toast")
    readonly property color scrollbar: roleColour("scrollbar")
    readonly property color tooltip: roleColour("tooltip")

    // ---- ink ----------------------------------------------------------------
    // Named by prominence. Same shape as a surface role, but only ScrollText honours
    // source or blend; plain Text takes the colour with opacity in its alpha. Ink
    // opacity never takes the master's; the window fade handles that.
    readonly property var inkRoles: ["text", "textSoft", "textDim", "textFaint", "textOverArt", "textOnAccent", "textOnSelected", "textOnActive", "textOnTitle", "close", "closeHover", "titleGlyph", "titleGlyphHover", "titleGlyphActive", "control", "controlOff", "controlHover", "highlight"]
    readonly property var inkFallback: ({
        text: "#e0e0e0", textSoft: "#aaaaaa", textDim: "#888888", textFaint: "#666666",
        textOnAccent: "#ffffff"   // the words on an accent button: white, whatever the text is
    })
    // Over artwork the halo is on by default: the over-artwork ink's default
    // effect is an adaptive outline, the inverse of the words, which a theme
    // can change or turn off.
    readonly property var inkEffectFallback: ({
        textOverArt: { kind: "outline", size: 1, soft: 0, dx: 0, dy: 0,
                       colour: { source: "adaptive" }, opacity: 0.85 }
    })
    function inkFrom(pal, opacities, name) {
        // A blue title bar needs white captions without whitening library
        // labels. Unset, it takes textDim's whole ink and opacity.
        if (name === "textOnTitle" && pal[name] === undefined) {
            const inherited = inkFrom(pal, opacities, "textDim")
            if (opacities[name] !== undefined) inherited.opacity = opacities[name]
            return inherited
        }
        // Inks added after themes were written follow an older one (textOverArt
        // follows text, source included, so an adaptive `text` adapts over art too).
        const v = pal[name] !== undefined ? pal[name]
                : (name === "textOverArt" ? pal.text : name === "control" ? pal.textSoft
                   : name === "controlOff" ? pal.borderStrong : name === "controlHover" ? pal.text
                   : name === "textOnSelected" ? pal.text
                   // the words on an active button follow the selected surface's: that is
                   // the face buttonActive follows
                   : name === "textOnActive" ? (pal.textOnSelected !== undefined ? pal.textOnSelected : pal.text)
                   : name === "close" ? pal.textDim : name === "closeHover" ? pal.text
                   // the title bar's other buttons follow the words they sat as
                   : name === "titleGlyph" ? pal.textDim : name === "titleGlyphHover" ? pal.text
                   : name === "titleGlyphActive" ? (pal.textOnActive !== undefined ? pal.textOnActive
                                                   : pal.textOnSelected !== undefined ? pal.textOnSelected : pal.text)
                   : name === "highlight" ? pal.accent : undefined)
        const own = opacities[name] !== undefined ? opacities[name] : 1
        const fb = inkEffectFallback[name] !== undefined
                 ? effectOf({ effect: inkEffectFallback[name] }) : undefined
        return ({
            colour: flatColour(v, inkFallback[name] || inkFallback.text),
            opacity: own,
            source: sourceOf(v),
            blend: blendOf(v),
            amounts: adaptiveOf(v),
            params: styledOf(v),
            effect: effectOf(v, fb),
            layers: layersOf(v),
        })
    }
    function inkRole(name) {   // same hit path, same reason — see role()
        const g = memoGen(), e = memo.ink[name]
        if (e !== undefined && e.gen === g) return e.val
        return memoised(memo.ink, name, g, () => inkFrom(p, opacityMap, name))
    }
    // the ink's effect colour, resolved against the ink's own colour
    function inkEffectColour(name) {
        const r = inkRole(name)
        const c = r.source === "adaptive" ? adapt(roleColour("card"), r.amounts) : r.colour
        return effectColour(r.effect, c)
    }
    function inkColour(name) {
        const r = inkRole(name)
        // An adaptive ink still has to be a colour for ~130 plain Texts: they get the
        // shader's arithmetic against a flat backdrop (card), and ScrollText adapts per
        // pixel.
        const c = r.source === "adaptive" ? adapt(roleColour("card"), r.amounts) : r.colour
        return Qt.rgba(c.r, c.g, c.b, c.a * r.opacity)
    }

    // huelum.frag, in JS, for the readers that cannot run it. Keep the two in
    // step: the same hue rotation about the grey axis, the same Rec709
    // luminance, and the same "negative inverts, positive flips away from
    // mid-grey" rule. tst_paletteroles pins them against each other.
    function adapt(c, a) {
        const hue = a.x, lum = a.y, sat = a.z
        const k = 0.57735027
        const ca = Math.cos(hue * Math.PI), sa = Math.sin(hue * Math.PI)
        const dot = k * (c.r + c.g + c.b)
        // cross((k,k,k), c) — the order matters, and getting it backwards
        // rotates the hue the wrong way. tst_blendmodes compares this against
        // the shader and caught exactly that.
        const cl = (x) => Math.max(0, Math.min(1, x))
        let r = cl(c.r * ca + (k * c.b - k * c.g) * sa + k * dot * (1 - ca))
        let g = cl(c.g * ca + (k * c.r - k * c.b) * sa + k * dot * (1 - ca))
        let b = cl(c.b * ca + (k * c.g - k * c.r) * sa + k * dot * (1 - ca))
        // HSL, so lightness moves with hue and saturation kept — see huelum.frag
        const mx = Math.max(r, g, b), mn = Math.min(r, g, b)
        let h = 0, sl = 0
        const l = (mx + mn) / 2, d = mx - mn
        if (d > 1e-5) {
            sl = l < 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
            if (mx === r) h = (g - b) / d + (g < b ? 6 : 0)
            else if (mx === g) h = (b - r) / d + 2
            else h = (r - g) / d + 4
            h /= 6
        }
        sl = cl(sl * (1 + sat))
        const flip = l > 0.5 ? (1 - l) * (1 - l) : 1 - l * l
        const L2 = lum < 0 ? l + (1 - 2 * l) * (-lum) : l + (flip - l) * lum
        if (sl < 1e-5) return Qt.rgba(L2, L2, L2, c.a)
        const q = L2 < 0.5 ? L2 * (1 + sl) : L2 + sl - L2 * sl
        const p = 2 * L2 - q
        const h2 = (pp, qq, t) => {
            if (t < 0) t += 1
            if (t > 1) t -= 1
            if (t < 1 / 6) return pp + (qq - pp) * 6 * t
            if (t < 0.5) return qq
            if (t < 2 / 3) return pp + (qq - pp) * (2 / 3 - t) * 6
            return pp
        }
        return Qt.rgba(cl(h2(p, q, h + 1 / 3)), cl(h2(p, q, h)), cl(h2(p, q, h - 1 / 3)), c.a)
    }
    readonly property color text: inkColour("text")
    readonly property color textSoft: inkColour("textSoft")
    readonly property color textDim: inkColour("textDim")
    readonly property color textFaint: inkColour("textFaint")
    readonly property color textOverArt: inkColour("textOverArt")
    readonly property color control: inkColour("control")
    readonly property color controlOff: inkColour("controlOff")
    readonly property color controlHover: inkColour("controlHover")
    readonly property color textOnAccent: inkColour("textOnAccent")
    readonly property color textOnSelected: inkColour("textOnSelected")
    readonly property color textOnActive: inkColour("textOnActive")
    readonly property color textOnTitle: inkColour("textOnTitle")
    readonly property color close: inkColour("close")
    readonly property color closeHover: inkColour("closeHover")
    readonly property color titleGlyph: inkColour("titleGlyph")
    readonly property color titleGlyphHover: inkColour("titleGlyphHover")
    readonly property color titleGlyphActive: inkColour("titleGlyphActive")
    readonly property color highlight: inkColour("highlight")

    readonly property color accent: colorOf(p.accent, "#cc3333")
    // What reads on top of a filled chip. Text on the accent — or on any
    // ink-filled pill — is black or white by the fill's own luminance, like
    // textContrast; the window colour is nearly white on a light theme.
    function onFill(fill) {
        const q = Qt.color(fill)
        return (0.299 * q.r + 0.587 * q.g + 0.114 * q.b) > 0.5 ? "#000000" : "#ffffff"
    }
    readonly property color onAccent: onFill(accent)
    readonly property color accentHover: colorOf(p.accentHover, "#dd4444")
    // the seek bar's played fill: its own key, following accent until set
    readonly property color scrubber: roleColour("scrubber")
    // the equaliser's curve and nodes
    readonly property color graph: roleColour("graph")
    // the active tab's underline, in the settings window and the queue panel
    readonly property color tabLine: roleColour("tabLine")
    readonly property color border: colorOf(p.border, "#2a2a2a")
    readonly property color borderStrong: colorOf(p.borderStrong, "#444444")
    // Failure, distinct from accent: accent is a theme's identity and several
    // palettes make it green or blue, which is the wrong colour for "this
    // did not work".
    readonly property color danger: colorOf(p.danger, "#e05252")

    // "squared" corner style zeroes every radius app-wide
    readonly property bool squared: ts.cornerStyle === "squared"
    readonly property int radiusSm: squared ? 0 : 2
    readonly property int radiusMd: squared ? 0 : 4
    readonly property int radiusLg: squared ? 0 : 8
    // pills (chips, toggles, round buttons); callers pass their height/2
    function pill(r) { return squared ? 0 : r }

    // font: numeric CSS weights map directly onto Qt6's 1-1000 scale.
    // A named family may be missing on this machine; Qt would substitute silently,
    // so fall back to the shipped font.
    readonly property string fontRequested: ts.font || "Red Hat Display"
    readonly property bool fontMissing:
        typeof ThemeBackend !== "undefined" && !ThemeBackend.hasFont(fontRequested)
    readonly property string fontFamily:
        typeof ThemeBackend !== "undefined" ? ThemeBackend.resolveFont(fontRequested)
                                            : fontRequested
    readonly property real fontScale: ts.fontScale || 1
    // ONE scale for the whole interface, and a text OFFSET on top of it.
    // uiScale moves everything — type, rows, controls, icons, thumbnails, the
    // player bar. fontScale then moves only the type, relative to that, for
    // people who want the words bigger than the furniture.
    readonly property real uiScale: ts.uiScale || 1
    function fs(base) { return Math.round(base * uiScale * fontScale) }

    // sp() sizes the space text needs (row heights, columns) with the text. Families
    // differ at the same pixelSize (Poppins is a third taller than Red Hat Display at
    // 12px), so the ratio is measured against the font literals were picked for.
    // Measured at the text offset only: sp() applies uiScale itself.
    readonly property FontMetrics fmCur: FontMetrics {
        font.family: Theme.fontFamily
        font.pixelSize: Math.max(1, Math.round(12 * Theme.fontScale)) }
    readonly property FontMetrics fmRef: FontMetrics {
        font.family: "Red Hat Display"; font.pixelSize: 12 }
    // Never below 1: the literals sp() replaced are hand-tuned MINIMUMS —
    // room for an icon, a thumbnail, a border — not measurements of the type.
    // A short font is free to leave more air; it does not get to shrink a row.
    readonly property real spScale: Math.max(
        1, fmRef.height > 0 ? fmCur.height / fmRef.height : fontScale)
    function sp(base) { return Math.round(base * uiScale * spScale) }

    // Offsets on the interface size, each ×1 by default, so a thing can be
    // bigger or smaller than everything else without leaving the scale.
    // sp() is not one of them: it is the room TEXT needs, so it answers to
    // the type, not to a preference about furniture.
    readonly property real spacingScale: ts.spacingScale || 1
    readonly property real controlScale: ts.controlScale || 1
    readonly property real artScale: ts.artScale || 1
    readonly property real barScale: ts.barScale || 1

    // gaps, padding, page margins
    function gap(base) { return Math.round(base * uiScale * spacingScale) }
    // buttons, toggles, icons — the things you click
    function ctl(base) { return Math.round(base * uiScale * controlScale) }
    // thumbnails and tiles
    function art(base) { return Math.round(base * uiScale * artScale) }
    // the player bar
    function bar(base) { return Math.round(base * uiScale * barScale) }
    readonly property int weightBase: ts.fontWeight || 400
    readonly property int weightMedium: Math.min(900, weightBase + 100)
    readonly property int weightBold: Math.min(900, weightBase + 200)
    // The title bar's words: their size before the scales, and their weight;
    // 0 is medium
    readonly property real titleFontSize: ts.titleFontSize !== undefined ? Number(ts.titleFontSize) : 12
    readonly property int titleWeight: Number(ts.titleFontWeight) > 0 ? Number(ts.titleFontWeight) : weightMedium

    // theme settings surfaced for QML (hover fade, mini)
    readonly property real hoverOpacity: ts.hoverOpacity !== undefined ? ts.hoverOpacity : 0.3
    // fade trigger: "off" | "hover" (mouse away) | "focus" (window inactive)
    readonly property string fadeMode: ts.fadeMode || "off"
    readonly property string miniFadeMode: ts.miniFadeMode || "off"
    // the search row and the tab row, one under the other or one row
    readonly property bool headerCombined: ts.header === "combined"
    function headerCanCombine(availableWidth, tabsWidth) {
        // Reserve a usable field as well as the filter button. A combined
        // theme at the default 400px width otherwise loses search entirely
        // and puts the filter button over the last tab.
        return headerCombined && availableWidth >= tabsWidth + sp(160) + iconBtn + gap(4)
            + inset("header", "left") + inset("header", "right")
    }
    // What a framed control's face is. a push button, a chip and an option
    // chip are buttons; a dropdown is a button unless the theme draws it as
    // an input. One answer for every framed control.
    readonly property bool inputSelects: ts.inputSelects === true || ts.inputSelects === "on"
    // What a held button does: nothing, take the `buttonPress` face, or take
    // it and move its content a pixel down and right. Not named `buttonPress`
    // here because that is the colour property of the role of the same name —
    // the setting picks the look, the role paints it.
    readonly property string pressStyle: ts.buttonPress || "none"
    // `active` is a button that is ON — the chosen layout, the open filter
    // row, the selected tab. Held still wins over it: press is what the hand
    // is doing now.
    function faceOf(kind, hovered, pressed, active) {
        if (kind === "close") return pressed && pressStyle !== "none" ? "closeFacePress" : (hovered ? "closeFaceHover" : "closeFace")
        // The title bar's other buttons have faces of their own, which follow
        // the button's until a theme gives them a title bar's look
        if (kind === "title") {
            if (pressed === true && pressStyle !== "none") return "titleButtonPress"
            if (active === true) return "titleButtonActive"
            return hovered ? "titleButtonHover" : "titleButton"
        }
        // The primary one keeps its colour while held. Turning the accent
        // grey under the finger loses the one thing it is there to say —
        // which button the dialog wants. It still sinks: `pressShift` is the
        // caller's, and the shift is what says the press landed.
        if (kind === "accent") return hovered ? "accentHover" : "accent"
        // a dropdown drawn as an input keeps the input's face: it is a field,
        // and a field does not sink
        if (kind === "select" && inputSelects) return hovered ? "hover" : "input"
        if (pressed === true && pressStyle !== "none") return "buttonPress"
        // On is already the answer. a button that is the current choice does
        // not light up under the pointer: hover says "this is what you would
        // pick", and there is nothing to pick — the chosen layout, the open
        // filter row, a tab in the button style all stay put.
        if (active === true) return "buttonActive"
        return hovered ? "buttonHover" : "button"
    }
    // how far a held button's content moves, in px — 0 unless the theme sinks
    function pressShift(pressed) { return pressed === true && pressStyle === "sink" ? 1 : 0 }
    // Whether a bare icon sits on a button face, per place: the title bar's
    // window buttons, a page's tools, the transport and the bar's buttons.
    // `bare` is the icon alone, the default.
    readonly property string titleButtons: ts.titleButtons || "bare"
    readonly property string toolButtons: ts.toolButtons || "bare"
    readonly property string transportButtons: ts.transportButtons || "bare"
    // the air between two tabs, in spacing units; none between segments
    readonly property real tabGap: ts.tabGap !== undefined ? Number(ts.tabGap) : 2
    // the tabs' height in the filled, pill and segment styles — the header's,
    // the settings window's and the queue's — and a segment track's padding
    // around the tabs it holds
    readonly property real tabHeight: ts.tabHeight !== undefined ? Number(ts.tabHeight) : 22
    readonly property real tabTrackPad: ts.tabTrackPad !== undefined ? Number(ts.tabTrackPad) : 4
    // between two icon buttons in a group: the title bar's window buttons,
    // a page's layout toggle. The player bar's are in its layout.
    readonly property real buttonGap: ts.buttonGap !== undefined ? Number(ts.buttonGap) : 2
    // The sizes a button is made of, in pixels at ×1 control scale: a push
    // button's height, a framed icon button's square, and a glyph's size —
    // each then scaled by the control size like everything clickable
    readonly property real buttonHeight: ts.buttonHeight !== undefined ? Number(ts.buttonHeight) : 22
    readonly property real iconButtonSize: ts.iconButtonSize !== undefined ? Number(ts.iconButtonSize) : 26
    readonly property real glyphSize: ts.glyphSize !== undefined ? Number(ts.glyphSize) : 14
    // A slider and a toggle are made of sizes too, in the same pixels at ×1
    // control scale: the rail, the knob on it, the toggle's track.
    readonly property real sliderTrackHeight: ts.sliderTrackHeight !== undefined ? Number(ts.sliderTrackHeight) : 4
    readonly property real sliderKnobSize: ts.sliderKnobSize !== undefined ? Number(ts.sliderKnobSize) : 12
    readonly property string sliderKnobShape: ts.sliderKnobShape || "round"
    // A thumb need not be round: a capsule — a seek thumb wider than it is
    // tall, a volume thumb standing upright — is a shape a circle cannot take
    // at any size. Width divided by height; 1 is square.
    readonly property real sliderKnobAspect: ts.sliderKnobAspect > 0 ? Number(ts.sliderKnobAspect) : 1
    // The volume rail is its own control, sized apart from the sliders in
    // Settings, so a volume thumb cut to a sprite's proportions changes no
    // other slider. 0 (or "") here follows the slider.
    readonly property real volumeTrackHeight: ts.volumeTrackHeight > 0 ? Number(ts.volumeTrackHeight) : sliderTrackHeight
    readonly property real volumeKnobSize: ts.volumeKnobSize > 0 ? Number(ts.volumeKnobSize) : sliderKnobSize
    readonly property real volumeKnobAspect: ts.volumeKnobAspect > 0 ? Number(ts.volumeKnobAspect) : sliderKnobAspect
    readonly property string volumeKnobShape: ts.volumeKnobShape || sliderKnobShape
    readonly property string volumeTrackShape: ts.volumeTrackShape || sliderTrackShape
    readonly property real volumeKnobInset: ts.volumeKnobInset >= 0 && ts.volumeKnobInset !== undefined
                                            ? Number(ts.volumeKnobInset) : sliderKnobInset
    readonly property string sliderTrackShape: ts.sliderTrackShape || "round"
    readonly property string scrubberShape: ts.scrubberShape || "round"
    // Where the knob sits at 0% AND 100%: its centre, in pixels from the
    // rail's end, inward. Unset it is half the knob, so the knob just fits
    // inside the rail; 0 puts its centre on the end, and a
    // negative number hangs it past.
    readonly property real sliderKnobInset: ts.sliderKnobInset !== undefined && Number(ts.sliderKnobInset) >= 0 ? Number(ts.sliderKnobInset) : sliderKnobSize / 2
    // The seek bar's knob is its own: a size (0 is none, the default), a
    // shape, a rest, and the `scrubberKnob` colour — a
    // slider and a seek bar are different graphics
    readonly property real scrubberKnobSize: ts.scrubberKnobSize !== undefined ? Number(ts.scrubberKnobSize) : 0
    readonly property string scrubberKnobShape: ts.scrubberKnobShape || "round"
    readonly property real scrubberKnobAspect: ts.scrubberKnobAspect > 0 ? Number(ts.scrubberKnobAspect) : 1
    // whether the seek bar thickens under the pointer
    readonly property bool scrubberGrow: ts.scrubberHover === undefined || ts.scrubberHover === "grow"
    readonly property real scrubberKnobInset: ts.scrubberKnobInset !== undefined && Number(ts.scrubberKnobInset) >= 0 ? Number(ts.scrubberKnobInset) : scrubberKnobSize / 2
    // What a scrollbar is: the thin pill that fades when idle, or a slider —
    // the slider's rail the whole way, its knob as the thumb, always shown
    readonly property string scrollbars: ts.scrollbars || "bar"
    // The ridges on the thumb, as the scrollbars of that era carried: three
    // lines across its middle, in the control ink, drawn only where there is
    // room for them. `none` is the default.
    readonly property string scrollbarGrip: ts.scrollbarGrip || "none"
    // how thick the whole thing is; 0 takes the slider's sizes
    readonly property real scrollbarWidth: ts.scrollbarWidth > 0 ? Number(ts.scrollbarWidth) : 0
    // a loading placeholder: a sheen sweeping across, the whole thing
    // breathing, or still
    readonly property string skeletonStyle: ts.skeletonStyle || "shimmer"
    // Whether the skeleton role needs a surface — what Surface.blending
    // would say of it — answered once here. Asked by a closure in each of
    // the several hundred skeletons live at once, with a GridView building
    // and dropping dozens mid-drag, it would be most of a resize's polish time.
    readonly property bool skeletonStyled: {
        const r = role("skeleton")
        return r.blend.length > 0 || r.source === "adaptive" || layered(r)
    }
    // Room beside a scroller's bar: the scrollbar inset's left gap, plus for a
    // slider (always-present rail) the rail and its right inset. The thin bar overlays
    // the content.
    readonly property real scrollGutter: inset("scrollbar", "left")
        + (scrollbars === "slider" ? ctl(Math.max(sliderTrackHeight, sliderKnobSize)) + inset("scrollbar", "right") : 0)
    readonly property real toggleWidth: ts.toggleWidth !== undefined ? Number(ts.toggleWidth) : 36
    readonly property real toggleHeight: ts.toggleHeight !== undefined ? Number(ts.toggleHeight) : 20
    readonly property string toggleKnobShape: ts.toggleKnobShape || "round"
    // A knob's shape is its own key, not the corner style's business: a theme
    // that squares every corner can still want a round knob to grab, and
    // `squared` folding it back would leave the key with nothing to do.
    function knobRadius(shape, size) { return shape === "square" ? radiusSm : size / 2 }
    // a rail squared is square: at 4px there is no small radius to speak of
    function trackRadius(shape, size) { return shape === "square" ? 0 : size / 2 }
    readonly property real btnH: ctl(buttonHeight)
    readonly property real iconBtn: ctl(iconButtonSize)
    // the title bar's buttons, square; 0 is the icon button size
    readonly property real titleBtn: Number(ts.titleButtonSize) > 0 ? ctl(Number(ts.titleButtonSize)) : iconBtn
    // ...and how tall the face is: the size when a theme names one, or no
    // taller than the bar leaves
    // A title bar's height: its insets round 24, or round the buttons when a
    // theme sizes them, so a title bar can be as short as its buttons are
    readonly property real titleBarH: (Number(ts.titleButtonSize) > 0 ? titleBtn : 24)
                                      + inset("title", "top") + inset("title", "bottom")
    readonly property real titleBtnH: Number(ts.titleButtonSize) > 0 ? titleBtn
                                      : Math.min(iconBtn, ctl(20) + inset("title", "top") + inset("title", "bottom"))
    function glyph(base) { return ctl(base * glyphSize / 14) }
    readonly property string viewTabs: ts.viewTabs || "filled"
    // Content inset from a surface's edge, per structure and side, in interface
    // pixels. A theme gives one number or {left, top, right, bottom}. uiScale moves
    // them; the spacing preference does not.
    readonly property var insetSides: ["left", "top", "right", "bottom"]
    readonly property var insetDefaults: ({
        page:    [10, 10, 10, 10],   // the views' content from the page edge
        // A view's heading block — its title, source line and tool row —
        // measured from the page's own edge, never added to `page`: one
        // visible edge takes one inset, or setting both moved the block
        // twice. The bottom is the gap between it and the content below.
        pageHeader: [10, 10, 10, 10],
        header:  [10, 5, 10, 5],     // the search row's field and toggle
        tabs:    [8, 0, 8, 5],       // the tab bar's first tab from its left; below, the air above it (header bottom + tabs top)
        title:   [10, 0, 4, 0],      // a title bar's label and buttons
        player:  [12, 6, 12, 6],     // the bar's cells from the bar edge
        panel:   [12, 6, 12, 6],     // the queue panel's rows and header
        row:     [6, 6, 16, 6],      // a list row's thumbnail and text; the
                                     // right holds a right-aligned duration
        input:   [8, 0, 8, 0],       // a text input's text from its box
        menu:    [5, 5, 5, 5],       // a menu's rows from its edge
        dialog:  [16, 16, 16, 16],   // a dialog's body
        toast:   [10, 5, 10, 5],     // a toast's words
        tooltip: [8, 5, 8, 5],       // a tooltip's words
        settings: [16, 12, 16, 12],  // a settings row's label and control from the row's edge
        settingsHover: [0, 0, 0, 0], // the row's hover fill from the row's edge
        tool:    [10, 10, 10, 10],   // a tool window's body: the picker, the gallery, the shelf, the equaliser
        scrollbar: [2, 2, 2, 2],     // left: the content from the bar; right, top, bottom: the bar from the scroller's edge
        // A card's, in units of a 160-WIDE TILE — a card is laid out in those
        // and drawn at its width, so these scale with it, not with uiScale
        cardArt: [0, 0, 0, 0],       // the picture from the card's edge
        cardText: [8, 0, 8, 8]       // the text from the left, the picture, the right, the bottom
    })
    readonly property var insetNames: Object.keys(insetDefaults)
    readonly property string insetKey: JSON.stringify(ts.insets !== null && typeof ts.insets === "object" ? ts.insets : ({}))
    readonly property var insetMap: JSON.parse(insetKey)
    function insetOf(name, side) {   // unscaled, as the theme says it
        const d = insetDefaults[name] || [0, 0, 0, 0], i = Math.max(0, insetSides.indexOf(side))
        const v = insetMap[name]
        if (typeof v === "number") return v
        if (v !== null && typeof v === "object" && v[side] !== undefined) return Number(v[side])
        if (name === "input" && insetMap.field !== undefined) return insetOf_(insetMap.field, side, d[i])   // its first name
        // the card's first cut was one number each, under its own keys
        if (name === "cardArt" && ts.cardArtInset !== undefined) return Number(ts.cardArtInset)
        if (name === "cardText" && ts.cardTextInset !== undefined && side !== "top") return Number(ts.cardTextInset)
        return d[i]
    }
    // A card's inset in tile units, for MediaTile to scale. Cards scale with the
    // card, not uiScale, so they cannot read insetPx; memoised like it (a per-call
    // walk was 18,550 calls in a four-second drag).
    readonly property var cardInsetRaw: {
        const out = ({})
        for (const name of insetNames) {
            const e = ({})
            for (const side of insetSides) e[side] = insetOf(name, side)
            out[name] = e
        }
        return out
    }
    function cardInset(name, side) {
        const e = cardInsetRaw[name]
        return e === undefined ? insetOf(name, side) : e[side]
    }
    function insetOf_(v, side, dflt) {
        if (typeof v === "number") return v
        if (v !== null && typeof v === "object" && v[side] !== undefined) return Number(v[side])
        return dflt
    }
    // Resolved once per theme, not per call: inset() has ~190 binding sites and was
    // the busiest function during a resize (~5,000 calls/s). `insetOf` remains for
    // the unscaled values settings rows show.
    readonly property var insetPx: {
        const out = ({}), sc = uiScale
        for (const name of insetNames) {
            const e = ({})
            for (const side of insetSides) e[side] = Math.round(insetOf(name, side) * sc)
            out[name] = e
        }
        return out
    }
    // A list row's inset in the compact layout: tighter by `by`, and never
    // past what the theme asked for; a negative inset (rows bleeding over the
    // edge) is kept.
    function rowInset(side, by) {
        const v = inset("row", side)
        return Math.max(Math.min(v, 0), v - by)
    }
    function inset(name, side) {
        const e = insetPx[name]
        return e === undefined ? Math.round(insetOf(name, side) * uiScale) : e[side]
    }

    // Glyph definitions: viewBox (24 unless given), `ink` extent, fill or stroke,
    // path data. Here so a theme's `glyphs` setting (same shape, keyed by name) can
    // replace one; missing names draw the built-in.
    readonly property var glyphDefaults: ({
        play:  { fill: true, ink: 17.0,  paths: ["M6 3.5L20 12L6 20.5V3.5Z"] },
        pause: { fill: true, ink: 18.0,  paths: ["M5 3H10V21H5Z", "M14 3H19V21H14Z"] },
        prev:  { fill: true, ink: 18.0,  paths: ["M4 3H7V21H4Z", "M20 3.5L9 12L20 20.5V3.5Z"] },
        next:  { fill: true, ink: 18.0,  paths: ["M4 3.5L15 12L4 20.5V3.5Z", "M17 3H20V21H17Z"] },
        eq:    { fill: false, ink: 24.0, paths: ["M4 21V14", "M4 10V3", "M12 21V12", "M12 8V3",
                                      "M20 21V16", "M20 12V3", "M1 14H7", "M9 8H15", "M17 16H23"] },
        queue: { fill: false, ink: 18.5, sw: 2.5, paths: ["M4 6H20", "M4 12H20", "M4 18H14"] },
        search:{ fill: false, ink: 20.0, paths: ["M11 19A8 8 0 1 0 11 3A8 8 0 0 0 11 19Z", "M21 21L16.65 16.65"] },
        close: { fill: false, ink: 14.0, paths: ["M18 6L6 18", "M6 6L18 18"] },
        check: { fill: false, ink: 16.0, paths: ["M5 13L9.5 17.5L19 7"] },
        minimize: { fill: false, ink: 16.0, paths: ["M5 12H19"] },
        maximize: { fill: false, ink: 16.0, paths: ["M5 5H19V19H5Z"] },
        restore:  { fill: false, ink: 16.0, paths: ["M5 9H15V19H5Z", "M9 9V5H19V15H15"] },
        pin:   { fill: false, ink: 20.0, paths: ["M12 17V22", "M5 17H19L17 10H7L5 17Z", "M9 10V4H15V10"] },
        minus: { fill: false, ink: 16.0, paths: ["M5 12H19"] },
        shuffle: { fill: false, ink: 20.5, paths: ["M16 3H21V8", "M4 20L21 3", "M21 16V21H16",
                                        "M15 15L21 21", "M4 4L9 9"] },
        filter: { fill: true, ink: 14.0, paths: ["M12 5A2 2 0 1 0 12 9A2 2 0 1 0 12 5Z",
                                      "M12 10A2 2 0 1 0 12 14A2 2 0 1 0 12 10Z",
                                      "M12 15A2 2 0 1 0 12 19A2 2 0 1 0 12 15Z"] },
        settings: { fill: false, ink: 24.0, paths: ["M9 12A3 3 0 1 0 15 12A3 3 0 1 0 9 12",
            "M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"] },
        plus:  { fill: false, ink: 16.0, paths: ["M12 5V19", "M5 12H19"] },
        alert: { fill: false, ink: 23.0, paths: ["M12 3L1.5 21H22.5L12 3Z", "M12 10V14", "M12 17.5V17.6"] },
        // broadcast: a source with two pairs of waves off it (song radio)
        radio: { fill: false, ink: 20.5, paths: ["M12 11A1 1 0 1 0 12 13A1 1 0 1 0 12 11Z",
                                      "M8.6 15.4a4.8 4.8 0 0 1 0-6.8",
                                      "M15.4 8.6a4.8 4.8 0 0 1 0 6.8",
                                      "M5.6 18.4a9 9 0 0 1 0-12.8",
                                      "M18.4 5.6a9 9 0 0 1 0 12.8"] },
        chevron: { fill: false, ink: 16.0, paths: ["M9 5L16 12L9 19"] },   // right; rotate for down
        vis:   { fill: false, ink: 22.0, paths: ["M2 12C4 12 4 6 7 6C10 6 10 18 13 18C16 18 16 9 18 9C20 9 20 12 22 12"] },
        // layout glyphs use a 14x14 viewBox
        layoutList:    { fill: true, vb: 14, ink: 14.0, paths: ["M0 1H14V3.5H0Z", "M0 5.75H14V8.25H0Z", "M0 10.5H14V13H0Z"] },
        layoutGrid:    { fill: true, vb: 14, ink: 14.0, paths: ["M0 0H6V6H0Z", "M8 0H14V6H8Z", "M0 8H6V14H0Z", "M8 8H14V14H8Z"] },
        layoutCompact: { fill: true, vb: 14, ink: 14.0, paths: ["M0 0.5H14V2.5H0Z", "M0 4H14V6H0Z", "M0 7.5H14V9.5H0Z", "M0 11H14V13H0Z"] }
    })
    readonly property var glyphNames: Object.keys(glyphDefaults)
    // Held as a string, as the insets are: `ts` is a new map on every settings
    // write, so reading the object out of it would re-draw every icon in the
    // window whenever anything at all was set.
    readonly property string glyphKey: JSON.stringify(ts.glyphs !== null && typeof ts.glyphs === "object" ? ts.glyphs : ({}))
    readonly property var glyphMap: JSON.parse(glyphKey)
    readonly property var glyphTable: Object.assign({}, glyphDefaults, glyphMap)
    function glyphOf(name) { return glyphTable[name] }
    // the picture's corners — auto is the card's at the edge and small inside it
    readonly property string cardArtCorners: ts.cardArtCorners || "auto"
    readonly property string chips: ts.chips || "pill"
    readonly property string pageTabs: ts.pageTabs || "underline"
    readonly property string toggles: ts.toggles || "segment"
    // THE PLAYER: which layout each place gets (rows, centre, strip), on which
    // backing (the player surface, none, or a floating card), how the two
    // swap, and where centre puts its scrub bar
    readonly property string barMain: ts.barMain || "rows"
    readonly property string barNp: ts.barNp || "centre"
    readonly property string barMini: ts.barMini || "rows"
    readonly property string backMain: ts.backMain || "surface"
    // the floating card: its margin from the bar's edges, and how far it sits
    // below (+) or above (-) the middle — px, before the spacing scale
    readonly property real floatInset: ts.floatInset !== undefined ? Number(ts.floatInset) : 10
    readonly property real floatOffset: ts.floatOffset !== undefined ? Number(ts.floatOffset) : 0
    readonly property string backNp: ts.backNp || "none"
    readonly property string backMini: ts.backMini || "surface"
    readonly property string barTransition: ts.barTransition || "rise"
    // how the bar's height changes: ease, spring (an overshoot), snap (a cut)
    readonly property string barResize: ts.barResize || "ease"
    // Side geometry at progress t (0 away, 1 at rest): x, y px and scale.
    // `toCentre` sets direction so arrivals come from the same side whichever layout;
    // tying the sign to the layout reversed one on the way back. Pure, for tests.
    function swapGeometry(swap, arriving, toCentre, t) {
        const away = 1 - t
        const dir = (toCentre ? 1 : -1) * (arriving ? 1 : -1)
        switch (swap) {
        case "rise":  return { x: 0, y: dir * 24 * away, s: 1 }
        case "drop":  return { x: 0, y: -dir * 24 * away, s: 1 }
        case "slide": return { x: dir * 24 * away, y: 0, s: 1 }
        case "zoom":  return { x: 0, y: 0, s: 1 + (arriving ? 0.04 : -0.04) * away }
        default:      return { x: 0, y: 0, s: 1 }   // fade, blur, none
        }
    }
    // the two sides' opacity: every swap overlaps — the leaving side fades as
    // the arriving one comes, each with its travel. Taking turns left the
    // bar empty in the middle, which read as a flash.
    function swapOverlaps(swap) { return true }
    readonly property string centreScrub: ts.centreScrub || "auto"
    // THE BUTTONS a bar can hold, melo's own; a plugin's is "plugin:<pluginId>.<id>"
    readonly property var buttonIds: ["library", "radio", "eq", "queue", "vis"]
    // instrumentation: how many bar cells have been built since start
    property int cellBuilds: 0
    // Motion: fast for state under the pointer, move for position/size changes,
    // swap for one thing replacing another (bar height, layout swap, backing fade).
    readonly property int motionFast: 120
    readonly property int motionMove: 180
    readonly property int motionSwap: 300
    // The bar's swap, its ground and its height take this instead of the token:
    // one thing giving way to another is the motion people watch most, and the
    // right length for it is a matter of taste. The token stays the default.
    readonly property int barSwapMs: {
        const v = Number(ts.barSwapMs)
        return isFinite(v) && v >= 0 ? v : motionSwap
    }
    readonly property int motionEase: Easing.OutCubic
    // ARRANGING: the main window's bar is being arranged by hand, for a
    // slot; the bar draws that slot's layout and takes the handles
    property bool arranging: false
    property string arrangeSlot: "barMain"
    // bumped when a layout is saved or rewritten, so a binding on a
    // document re-reads it: the store's lookup is a method, not a property
    property int layoutGen: 0
    // A SLOT'S DOCUMENT by key "slot:id": the slot's unsaved override if it
    // has one, else the layout the id names; mini as layoutDoc
    function slotDoc(key, mini) {
        const dep = layoutGen
        const i = String(key).indexOf(":")
        const slot = i >= 0 ? String(key).slice(0, i) : "", id = i >= 0 ? String(key).slice(i + 1) : String(key)
        // Keyed on slot, not instance: the mini bar renders the main slot's document
        // during the toggle handover, so instance-keyed stripping of mini-only cells or
        // the centre rewrite would apply to the wrong document for a frame.
        const keep = slot.length ? slot === "barMini" : mini === true
        if (slot.length && ThemeBackend.hasLayoutOverride(slot)) {
            const o = JSON.parse(JSON.stringify(ThemeBackend.layoutOverride(slot)))
            return stripMini(centred(o, keep), keep)
        }
        return stripMini(layoutDoc(id, keep), keep)
    }
    // `"mini": true` keeps a cell out of every document but the mini slot's, so
    // the visualizer differs by document and morphs in like any other cell. Nothing
    // here knows what a visualizer is.
    function stripMini(d, keep) {
        if (keep) return d
        const strip = (rows) => { for (const r of rows || []) r.cells = (r.cells || []).filter(c => c.mini !== true) }
        strip(d.rows)
        for (const v of d.variants || []) strip(v.rows)
        return d
    }
    function slotJson(key, mini) { return JSON.stringify(slotDoc(key, mini)) }
    function centred(d, mini) {
        if (d.id === "centre") {
            const mode = mini && centreScrub === "auto" ? "under" : centreScrub
            if (mode === "under") delete d.variants
            else if (mode === "edge") for (const v of d.variants || []) v.maxWidth = 1e9
        }
        return d
    }
    // A layout's document, ready to draw, with centre's narrow variant kept,
    // dropped or forced per centreScrub; in the mini player auto means under.
    function layoutDoc(id, mini) {
        const dep = layoutGen
        const d = JSON.parse(JSON.stringify(ThemeBackend.layoutDoc(id)))
        if (d.id === "centre") {
            const mode = mini && centreScrub === "auto" ? "under" : centreScrub
            if (mode === "under") delete d.variants
            else if (mode === "edge") for (const v of d.variants || []) v.maxWidth = 1e9
        }
        return d
    }
    readonly property real miniHoverOpacity: ts.miniHoverOpacity !== undefined ? ts.miniHoverOpacity : 0.3
    // The plain readers' style. Twenty-odd labels bind style/styleColor to
    // these; they follow the `text` ink's effect as Qt's nearest 1px style.
    // Anything that names an ink through ScrollText gets the real effect.
    readonly property int textStyle: effectStyle(inkRole("text").effect)
    readonly property color textStyleColor: {
        const e = inkRole("text").effect
        const q = inkEffectColour("text")
        return Qt.rgba(q.r, q.g, q.b, e.kind === "off" ? 0 : e.opacity)
    }
    // What contrasts with the text — dark under light text, light under dark.
    // For anything drawing text over a picture it did not choose, where the
    // background is unknown at design time and a fixed black scrim is only
    // right for half the palettes.
    readonly property color textContrast: {
        const t = Qt.color(text)
        return (0.299 * t.r + 0.587 * t.g + 0.114 * t.b) > 0.5 ? "#000000" : "#ffffff"
    }
    // Over artwork: the over-artwork ink's effect, as Qt's 1px style for the
    // plain readers (NpWords); on by default, see inkEffectFallback.
    readonly property int overArtStyle: effectStyle(inkRole("textOverArt").effect)
    readonly property color overArtStyleColor: {
        const e = inkRole("textOverArt").effect
        const q = inkEffectColour("textOverArt")
        return Qt.rgba(q.r, q.g, q.b, e.kind === "off" ? 0 : e.opacity)
    }

    readonly property string glassBlur: ts.glassBlur || "off"
    // blur behind the context and drop menus (their own windows)
    readonly property bool menuBlur: ts.menuBlur === "on" || ts.menuBlur === true
    // KWin background-contrast knobs (backdrop modulation under the blur).
    // Contrast and saturation only: intensity and frost are not read by any
    // current KWin.
    readonly property real glassContrast: ts.glassContrast !== undefined ? ts.glassContrast : 1
    readonly property real glassSaturation: ts.glassSaturation !== undefined ? ts.glassSaturation : 1
    // Contrast is not blur: they are two compositor effects, and this holds
    // with the blur setting off, which is the default. Translucency is still required, because the
    // effect acts on what is BEHIND the window and an opaque window hides it.
    readonly property bool wantContrast:
        translucent("window") && (glassContrast !== 1 || glassSaturation !== 1)
    readonly property int glassHoverDelay: ts.glassHoverDelay !== undefined ? ts.glassHoverDelay : 0
    readonly property int hoverFadeMs: ts.hoverFadeMs !== undefined ? ts.hoverFadeMs : 180
    // animated/static theme background (BackgroundLayer renders it).
    // {type, gradient, src, opacity, blur, options{...}}
    readonly property string backgroundKey: JSON.stringify(ts.background || ({ type: "none" }))
    readonly property var background: JSON.parse(backgroundKey)

    // window chrome
    readonly property int windowRadius: ts.windowRadius !== undefined ? ts.windowRadius : 4
    // which corners of the page surface take the window's radius: none, bottom, all
    readonly property string pageCorners: ts.pageCorners || "none"
    // the window border around the whole window, or around the window above a
    // detached bar and the bar apart: window, parts
    readonly property string windowBorderFit: ts.windowBorderFit || "window"
    // which header rows share one surface: separate, all, titleSearch, searchTabs
    readonly property string headerGroup: ts.headerGroup || "separate"
    // Window border (WindowBorder): windowBorder-role band round the window or each
    // part; width all round or per side; outer and inner lines; whether the title bar
    // runs over it; whether maximised keeps it. All widths are 0 while off.
    readonly property bool borderSides: ts.borderSides === true
    function borderSide(k) {
        if (!windowBorder) return 0
        return Number(borderSides && ts[k] !== undefined ? ts[k] : windowBorderWidth)
    }
    readonly property real borderLeft: borderSide("borderLeft")
    readonly property real borderTop: borderSide("borderTop")
    readonly property real borderRight: borderSide("borderRight")
    readonly property real borderBottom: borderSide("borderBottom")
    readonly property real borderOuterWidth: windowBorder ? Number(ts.borderOuterWidth || 0) : 0
    readonly property real borderInnerWidth: windowBorder ? Number(ts.borderInnerWidth || 0) : 0
    readonly property bool borderTitle: windowBorder && ts.borderTitle === true
    readonly property bool borderMaximized: ts.borderMaximized === true
    // The window's shape (WindowShapeItem): a theme's own — corners, an SVG
    // path or an image, see WindowShapeItem.h — or, without one, the rounded
    // corners a window actually draws. null is a plain rectangle, which needs
    // no mask at all.
    readonly property var windowShape: ts.windowShape && typeof ts.windowShape === "object"
                                       && ("corners" in ts.windowShape || "path" in ts.windowShape || "image" in ts.windowShape)
                                       ? ts.windowShape : null
    function roundedShape(top, bottom) {
        if (!(top > 0) && !(bottom > 0)) return null
        return { corners: [{ style: "round", size: top }, { style: "round", size: top },
                           { style: "round", size: bottom }, { style: "round", size: bottom }] }
    }
    function shapeFor(top, bottom) {
        if (windowShape) return windowShape
        return roundedShape(top, bottom)
    }
    // A path or an image is the player's shape alone. a cut worth having takes
    // a bite out of the window, and the player has a layout that can move out
    // of its way; a settings row cannot, so the row is the bite. Corners take
    // no row with them, so a theme's corners are every window's.
    function panelShapeFor(top, bottom) {
        if (windowShape && "corners" in windowShape) return windowShape
        return roundedShape(top, bottom)
    }
    // The frame's bands, outermost first: the theme's own list — each
    // { width, colour } or { width, role } — or the three the outer line, the
    // band and the inner line describe. The widths are one set for the whole
    // window; a side with less depth than their total shows the inner ones.
    readonly property var frameBands: {
        // A list from the settings is not a JS array — it arrives as Qt's own
        // list and Array.isArray says no — so it is read by length
        const bs = ts.windowFrame && typeof ts.windowFrame === "object" ? ts.windowFrame.bands : null
        if (bs && bs.length > 0) {
            const out = []
            for (let i = 0; i < Math.min(8, bs.length); ++i) out.push(bs[i])
            return out
        }
        const deep = Math.max(borderLeft, borderTop, borderRight, borderBottom)
        const out = []
        if (borderOuterWidth > 0) out.push({ width: borderOuterWidth, role: "windowBorderOuter" })
        const mid = Math.max(0, deep - borderOuterWidth - borderInnerWidth)
        if (mid > 0) out.push({ width: mid, role: "windowBorder" })
        if (borderInnerWidth > 0) out.push({ width: borderInnerWidth, role: "windowBorderInner" })
        return out
    }
    // how deep the frame is, over all its bands
    readonly property real frameDepth: {
        let at = 0
        for (const b of frameBands) at += Math.max(0, Number(b.width) || 0)
        return at
    }
    // How soft the frame's own edges are, in px: the outer one at the window's
    // rim, the inner one where it gives way to what it frames. The edges
    // between the bands stay hard.
    readonly property real borderSoftOuter: Math.max(0, Number(ts.borderSoftOuter || 0))
    readonly property real borderSoftInner: Math.max(0, Number(ts.borderSoftInner || 0))
    readonly property real borderSoftBands: Math.max(0, Number(ts.borderSoftBands || 0))
    readonly property string borderSoftCurve: ["linear", "smooth", "glow"].indexOf(String(ts.borderSoftCurve || "")) >= 0
                                              ? String(ts.borderSoftCurve) : "smooth"
    // how much of the band runs up beside a title bar in the border
    readonly property real borderTitleRim: borderTitle ? Math.max(0, Number(ts.borderTitleRim || 0)) : 0
    // ...and whether the rest of the band fades in beside the title's foot
    readonly property bool borderTitleFade: borderTitle && ts.borderTitleFade === true
    readonly property int windowRadiusBottom: ts.windowRadiusBottom !== undefined && Number(ts.windowRadiusBottom) >= 0
                                              ? Number(ts.windowRadiusBottom) : windowRadius
    readonly property bool windowBorder: ts.windowBorder === true
    // the window border is the palette role windowBorder; it follows
    // borderStrong unless a theme gives it its own
    readonly property color windowBorderColor: roleColour("windowBorder")
    readonly property int windowBorderWidth: ts.windowBorderWidth !== undefined ? ts.windowBorderWidth : 1
    // Whether the window's ground sits over the artwork (as a wash) rather than
    // under it. Over, adaptive or blended windows have a backdrop to read instead of
    // the hardware inversion.
    readonly property bool windowOverBackground: ts.windowOverBackground === true
}
