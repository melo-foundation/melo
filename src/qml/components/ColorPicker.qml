import QtQuick
import QtQuick.Window
import ".."

// The colour picker window: SV square, hue and alpha strips, code, old/new preview,
// and the layer stack where the caller allows it.
// open(entry, ctx) is the only way in: ctx.commit(value) on OK, ctx.preview(value)
// on every change, nothing on cancel; ctx.blend and ctx.adaptive say what this
// entry may become. A window so it can own the entry's state and host popups,
// which an overlay inside a modal cannot.
Window {
    id: picker
    visible: false
    color: "transparent"
    title: "melo colour"
    flags: Qt.Window | Qt.FramelessWindowHint
    minimumWidth: Theme.sp(300)
    minimumHeight: Math.round(titleBar.height + dialog.fullHeight)

    property real hue: 0          // 0..1
    property real sat: 1
    property real val: 1
    property real alpha: 1
    // "" for an ordinary colour; otherwise the palette entry is a blend mode
    // and the colour below is its SOURCE, not the surface's appearance.
    property string blendMode: ""
    // A plain colour with no blend is stored as the colour string. Source and blend
    // are separate lists because inverting and multiplying compose. Adaptive covers
    // invert (hue 0, lum -1, sat 0) plus hue shifts and flips away from mid-grey;
    // BlendItem keeps invert for the converter only.
    // Order: sources, fills, then filters, which draw nothing of their own and are
    // offered only where there is something under them.
    readonly property var sourceModes: ["colour", "adaptive"].concat(Theme.styledKinds).concat(Theme.filterNames)
    // Every hardware factor BlendItem implements. Pinned against it by
    // tst_themekeys: a mode offered here that it does not have draws nothing.
    readonly property var blendModes: ["normal", "multiply", "screen",
                                       "darken", "lighten", "subtract"]
    // Per layer: the bottom layer's blend is the entry's, against the window, which
    // nothing captures, so only the six GPU blend factors BlendRect implements. Higher
    // layers blend in stackblend.frag and get every mode, at an offscreen pass each.
    readonly property var blendChoices: layerAt > 0
        ? ["normal"].concat(Theme.blendCodes.slice(1)) : blendModes
    // Simple mode only dyes: a plain colour takes the colour, a stack or opal is
    // re-tinted and keeps its kind, so visiting in Simple never flattens anything.
    // Re-read once settings load; they arrive after the window is built.
    property bool advancedPref: typeof Settings !== "undefined"
                                ? (Settings.loaded, Settings.uiGet("pickerAdvanced", false) === true) : false
    // An entry Simple cannot edit does not get the Simple view. Dyeing needs a
    // layer with a base colour; an entry that is only contrast has none, and
    // a square that changes nothing is worse than the controls it replaced.
    readonly property bool canDye: {
        const ls = layers.length ? layers : [originalRaw]
        for (let i = 0; i < ls.length; ++i) {
            const src = Theme.sourceOf(ls[i])
            if (src === "colour" || Theme.fillBase(src)) return true
        }
        return false
    }
    readonly property bool advanced: advancedPref || !canDye
    // The last five entries made or applied, newest first, one of each: what
    // a swatch's right-click offers. Kept by value across sessions, and read
    // when asked, not bound: a var bound to a Settings read is evaluated once
    // at creation, before the file is in, and never again.
    property var recents: []          // the store itself where there is no Settings (a test)
    function recentList() {
        const v = typeof Settings !== "undefined" ? Settings.uiGet("recentEntries", []) : recents
        return Theme.isList(v) ? v : []
    }
    function remember(v) {
        const code = Theme.entryToCode(v)
        if (!code) return
        // by index: what Settings hands back is a QVariantList, which has a
        // length and no iterator
        const out = [v], was = recentList()
        for (let i = 0; i < was.length && out.length < 5; ++i)
            if (Theme.entryToCode(was[i]) !== code) out.push(was[i])
        recents = out
        if (typeof Settings !== "undefined") Settings.uiSet("recentEntries", out)
    }
    function setAdvanced(on) {
        advancedPref = on
        if (typeof Settings !== "undefined") Settings.uiSet("pickerAdvanced", on)
    }
    // the first layer a dye would land on, so the wheel is never showing a
    // colour that changes nothing
    function firstDyeable() {
        for (let i = 0; i < layers.length; ++i) {
            const src = Theme.sourceOf(layers[i])
            if (src === "colour" || Theme.fillBase(src)) return i
        }
        return 0
    }
    onAdvancedChanged: if (!advanced && !loading) selectLayer(firstDyeable())

    readonly property bool showSources: advanced && (blendable || adaptable)
    readonly property var levers: !advanced ? [] : (sourceMode === "adaptive" ? [
        { key: "adHue", label: "hue", from: -1, to: 1, step: 0.05 },
        { key: "adLum", label: "light", from: -1, to: 1, step: 0.05 },
        { key: "adSat", label: "sat", from: -1, to: 1, step: 0.05 },
        { key: "adOpacity", label: "alpha", from: 0, to: 1, step: 0.05 }
    ] : styled ? [
        { key: "stSpeed", label: "speed", from: -1, to: 1, step: 0.05 },
        { key: "stScale", label: sourceMode === "image" ? (imageFit === 5 ? "borders" : "zoom")
                              : sourceMode === "tidal" ? "size" : Theme.fillShape(sourceMode) ? "width" : "scale",
          inverse: sourceMode === "image", from: sourceMode === "image" ? 0.125 : 0.1,
          to: sourceMode === "image" ? 10 : 8, step: sourceMode === "image" ? 0.025 : 0.05 },
        { key: "stAngle", label: sourceMode === "tidal" ? "tilt" : ["contour", "trace", "doodle"].includes(sourceMode) ? "phase"
                                : Theme.fillShape(sourceMode) ? "light" : "angle", from: 0, to: 360, step: 1 }
    ] : []).concat(layerCount > 1 || !needsColour
        // A layer with no colour has no alpha either: the strip that carries
        // it belongs to the colour, so its own opacity is the only way to
        // fade a rainbow, an adaptive surface or a filter, whether or not
        // anything is stacked with it.
        ? [{ key: "layerOpacity", label: "opacity", from: 0, to: 1, step: 0.01 }] : [])
     .concat(layerCount > 1
        ? [{ key: "layerPhase", label: "phase", from: 0, to: 1, step: 0.01 }] : [])
     .concat(advanced && layerMask !== "all"
        ? [{ key: "layerMaskDist", label: "band", from: 0.5, to: 31.5, step: 0.5 },
           { key: "layerMaskSoft", label: "soft", from: 0, to: 16, step: 0.5 }] : [])
     .filter(o => sourceMode !== "image" || (imageFit === 0 || !["stSpeed", "layerPhase"].includes(o.key))
                  && (imageFit !== 5 || o.key !== "stAngle"))
    property string sourceMode: "colour"
    readonly property int imageFit: sourceMode === "image" ? optionOf("fit") : 0
    // An adaptive surface takes its colours from the backdrop, so it has no
    // source colour to choose: the swatch, the strips and the hex field would
    // all be controls that change nothing, and they hide.
    readonly property bool styled: Theme.isStyled(sourceMode)
    // A filter changes the layers under it and has nothing of its own: no
    // colour, no levers, no anchor, no blend — only its options.
    readonly property bool isFilterKind: Theme.isFilter(sourceMode)
    // the wheel shows whenever there is a colour to edit: a plain colour, a
    // base, or a stop of the palette
    readonly property bool needsColour: sourceMode === "colour" || hasBase || stops.length > 0
    // a styled fill's levers
    property real stSpeed: 0.3
    property real stScale: 1
    property real stAngle: 0
    property string stSrc: ""
    // A kind's own options for the selected layer, as edited. Held here rather
    // than read back out of the stored layer, so what the sliders say and what
    // gets written cannot drift, and so a kind whose options this build has
    // never heard of still rides through untouched.
    property var stOwn: ({})
    function optionOf(name) {
        if (sourceMode === "image") return Theme.imageOption(stOwn, name)
        const t = Theme.fillOptions(sourceMode)
        for (let i = 0; i < t.length; ++i)
            if (t[i].name === name)
                return stOwn[name] !== undefined ? parseFloat(stOwn[name]) : t[i].value
        return 0
    }
    function setOption(name, v) {
        const val = Number(parseFloat(v).toFixed(3))
        // A value already held is not a change. The slider's value is bound to
        // this and its live signal writes back through here, so echoing an
        // unchanged number would return a new `stOwn` object, re-evaluate the
        // binding, and go round again.
        if (optionOf(name) === val) return
        const o = ({})
        for (const k in stOwn) o[k] = stOwn[k]
        o[name] = val
        stOwn = o
        livePreview()
    }
    // The wheel edits one colour. A kind with a base shows the entry's colour as the
    // first swatch; a palette kind shows one swatch per stop (+ adds, − drops the
    // chosen one), or the kind's classic look with no stops.
    readonly property bool hasBase: sourceMode === "colour" || Theme.fillBase(sourceMode)
    readonly property bool hasPalette: Theme.fillPalette(sourceMode)
    property var stops: []                        // the palette, strings
    property int editing: -1                      // -1: the base colour, else a stop
    property string baseKept: "#ffffff"
    readonly property int colourCount: (hasBase ? 1 : 0) + stops.length
    readonly property bool twoColours: hasPalette || (hasBase && stops.length > 0)
    function loadOnWheel(c) {
        hue = c.hsvHue < 0 ? 0 : c.hsvHue; sat = c.hsvSaturation; val = c.hsvValue; alpha = c.a
    }
    function editColour(i) {
        if (i === editing) return
        if (editing < 0) baseKept = current.toString()
        else { const st = stops.slice(); st[editing] = current.toString(); stops = st }
        editing = i
        loadOnWheel(Theme.colorOf(i < 0 ? baseKept : stops[i], "#ffffff"))
        syncHex()
    }
    function addStop() {
        if (stops.length >= 6) return
        const st = stops.slice(); st.push(stops.length ? stops[stops.length - 1] : current.toString()); stops = st
        editColour(stops.length - 1); livePreview()
    }
    function removeStop() {
        if (editing < 0 || stops.length === 0) return
        const st = stops.slice(); st.splice(editing, 1); stops = st
        editing = st.length ? Math.min(editing, st.length - 1) : -1
        loadOnWheel(Theme.colorOf(editing < 0 ? baseKept : st[editing], "#ffffff"))
        syncHex(); livePreview()
    }
    // Where a stop sits is what it means: a gradient's stops are read in
    // order, so moving one is an edit of the palette, not of a colour. The
    // selected stop's colour lives on the wheel rather than in `stops`, so it
    // is written back before the swap or the move would drop it.
    function moveStop(d) {
        const j = editing + d
        if (editing < 0 || j < 0 || j >= stops.length) return
        const st = stops.slice()
        st[editing] = current.toString()
        const was = st[j]; st[j] = st[editing]; st[editing] = was
        stops = st
        editing = j
        livePreview()
    }
    readonly property color colour1: editing < 0 ? current : Theme.colorOf(baseKept, "#ffffff")
    function stopColour(i) { return editing === i ? current : Theme.colorOf(stops[i], "#ffffff") }
    readonly property var liveStops: { const out = []; for (let i = 0; i < stops.length; ++i) out.push(stopColour(i).toString()); return out }
    readonly property var liveParams: ({ speed: stSpeed, scale: stScale, angle: stAngle, colours: liveStops, src: stSrc })
    // hue, luminosity, saturation: -1..1 each, and only adaptive reads them.
    property real adHue: 0
    property real adLum: -1
    property real adSat: 0
    // 0..1, and the one amount a hardware mode could never have: half an
    // invert is not a blend factor, but half an adapted colour alpha-overed
    // onto the backdrop is just alpha.
    property real adOpacity: 1
    // The stack. Everything above is the SELECTED layer's working state, the
    // way `stops` and `editing` are one palette stop's: the other layers are
    // kept as entries and the selected one is written back into the list
    // whenever the selection moves. Bottom to top, as they are drawn.
    property var layers: []
    property int layerAt: 0
    readonly property int layerCount: Math.max(1, layers.length)
    // A layer's own opacity, and only where a second layer makes it mean
    // something: with one layer the colour's own alpha already is this.
    property real layerOpacity: 1
    // 0..1 of a turn, so two layers of one kind are not the same picture
    property real layerPhase: 0
    // Where the layer draws: the whole shape, a band within `layerMaskDist` px of
    // the edge, or everything beyond that band.
    property string layerMask: "all"
    property real layerMaskDist: 3
    // how far the band's edge fades; 0 is a hard line
    property real layerMaskSoft: 0
    // What the pattern is anchored to: the window (the default), this item,
    // or the content of whatever is scrolling it.
    property string layerSpace: "window"
    // View state, never committed: a layer switched off to see what it does,
    // or every other layer switched off to see only it.
    property var muted: []
    property int soloAt: -1
    function layerShown(i) { return soloAt >= 0 ? i === soloAt : !muted[i] }
    function toggleMute(i) {
        if (soloAt >= 0) soloAt = -1
        const m = muted.slice(); m[i] = !m[i]; muted = m
        livePreview()
    }
    function toggleSolo() { soloAt = soloAt === layerAt ? -1 : layerAt; livePreview() }

    // the selected layer written back into the list
    function layerEntries() {
        const out = layers.slice()
        if (out.length === 0) return [layerValue()]
        out[Math.max(0, Math.min(out.length - 1, layerAt))] = layerValue()
        // A stack is usually shades of one idea, so a dye re-tints every layer
        // that has a base colour and leaves the rest alone. Dyeing only the
        // selected one would leave the others contradicting it.
        if (!advanced) {
            const c = current.toString()
            for (let i = 0; i < out.length; ++i) {
                if (i === layerAt) continue
                const src = Theme.sourceOf(out[i])
                if (src !== "colour" && !Theme.fillBase(src)) continue
                if (typeof out[i] === "string") { out[i] = c; continue }
                const o = Object.assign({}, out[i]); o.colour = c; out[i] = o
            }
        }
        return out
    }
    function selectLayer(i) {
        if (i === layerAt || i < 0 || i >= layerCount) return
        const ls = layerEntries()
        layers = ls; layerAt = i
        loadLayer(ls[i])
        syncHex(true)
    }
    // A layer arrives still. Speed 0 by default is the whole mitigation for
    // having no cap: a stack costs what it costs, but the expensive part of it
    // is asked for rather than handed over.
    function addLayer() {
        const ls = layerEntries()
        ls.push(({ colour: current.toString(), source: "colour",
                   params: ({ speed: 0, scale: 1, angle: 0 }) }))
        layers = ls
        muted = muted.slice(0, ls.length - 1).concat([false])
        layerAt = ls.length - 1
        loadLayer(ls[layerAt])
        syncHex(true); livePreview()
    }
    function removeLayer() {
        if (layerCount <= 1) return
        const ls = layerEntries(); ls.splice(layerAt, 1)
        const m = muted.slice(); m.splice(layerAt, 1)
        layers = ls; muted = m
        layerAt = Math.min(layerAt, ls.length - 1)
        loadLayer(ls[layerAt])
        syncHex(true); livePreview()
    }
    function moveLayer(d) {
        const to = layerAt + d
        if (layerCount < 2 || to < 0 || to >= layerCount) return
        const ls = layerEntries(), m = muted.slice()
        const e = ls[layerAt]; ls[layerAt] = ls[to]; ls[to] = e
        const b = m[layerAt]; m[layerAt] = m[to]; m[to] = b
        layers = ls; muted = m; layerAt = to
        livePreview()
    }

    property color original: "#000000"
    property var cb: null
    // Called on every change while open. Optional: unset means no preview, not the
    // commit callback per mouse move (for the palette, a theme file write per frame).
    property var previewCb: null
    property var originalRaw: ""
    // Blend modes apply to a SURFACE that draws through Surface.qml. A
    // gradient stop, a visualiser colour or a palette entry nothing has
    // converted yet cannot be one, and offering the chips there would be a
    // control that does nothing — so the caller says whether they apply.
    property bool blendable: false
    // Source only: the entry can be a colour or adaptive but has no blend
    // axis — the text style, which Qt draws as one colour.
    property bool adaptable: false

    readonly property color current: Qt.hsva(hue, sat, val, alpha)
    // The same colour at full strength, for the strips: an alpha ramp drawn in
    // the colour it is ramping, and a hue bar that does not fade out with it.
    readonly property color opaque: Qt.hsva(hue, sat, val, 1)

    // One load path. `entry` is a colour string or an entry object; `ctx` is
    // { commit, preview, blend, adaptive }. Every field is set or reset here
    // and the code box lets go of focus as part of it, so nothing survives
    // from the entry opened before this one.
    property bool loading: false
    function load(entry, ctx) {
        // Let go of the field first, and ignore what that emits. Losing focus
        // emits editingFinished, which re-applies whatever text the box is
        // holding — the previous entry's code, or something half-typed — and
        // it lands on the entry being loaded rather than the one it came from.
        loading = true
        hexInput.focus = false
        const c = ctx || ({})
        const raw = entry
        originalRaw = raw
        cb = c.commit !== undefined ? c.commit : null
        previewCb = c.preview !== undefined ? c.preview : null
        blendable = c.blend === true
        adaptable = c.adaptive === true
        // Layers are kept as written, so options this build does not know survive a round
        // trip. Theme.isList: an entry from the settings store carries a QVariantList,
        // which is not an Array.
        layers = (raw !== null && typeof raw === "object" && Theme.isList(raw.layers) && raw.layers.length)
                 ? Array.prototype.slice.call(raw.layers) : [raw]
        muted = layers.map(() => false)
        soloAt = -1
        layerAt = advanced ? 0 : firstDyeable()
        entryFrom = (raw !== null && typeof raw === "object" && raw.from !== undefined)
                    ? String(raw.from) : ""
        loadLayer(layers[layerAt])
        // Through Theme.colorOf, not split(): the third field of "blend:adaptive:0,-1,0"
        // is numbers, and Qt.color() of it warns on every open. White when a blend entry
        // names no source.
        original = Theme.colorOf(raw, "#ffffff")
        loading = false
        syncHex(true)
    }
    // One layer onto the controls. load and every selection change go through
    // this, so the two cannot drift: what a layer is, is what these fields say.
    function loadLayer(raw) {
        const was = loading
        loading = true
        blendMode = Theme.blendOf(raw) || "normal"
        sourceMode = Theme.sourceOf(raw)
        const amt = Theme.adaptiveOf(raw)
        adHue = amt.x; adLum = amt.y; adSat = amt.z; adOpacity = amt.w
        const st = Theme.styledOf(raw)
        stSpeed = st.speed; stScale = st.scale; stAngle = st.angle; stSrc = st.src
        stOwn = st.own
        stops = st.colours.slice(); editing = -1
        layerOpacity = (raw !== null && typeof raw === "object" && raw.opacity !== undefined)
                       ? Math.max(0, Math.min(1, parseFloat(raw.opacity))) : 1
        layerPhase = (raw !== null && typeof raw === "object" && raw.phase !== undefined)
                     ? Math.max(0, Math.min(1, parseFloat(raw.phase))) : 0
        const lm = Theme.layersOf(raw)[0]
        layerMask = lm.mask; layerMaskDist = lm.maskDist; layerMaskSoft = lm.maskSoft; layerSpace = lm.space
        // From the layer being opened, not from `original`, which is still the
        // PREVIOUS entry here. The styled fill's base reads baseKept, so
        // `original` would carry the previous role's colour into this one.
        baseKept = Theme.colorOf(raw, "#ffffff").toString()
        const cur = Theme.colorOf(raw, "#ffffff")
        hue = cur.hsvHue < 0 ? 0 : cur.hsvHue
        sat = cur.hsvSaturation
        val = cur.hsvValue
        alpha = cur.a
        loading = was
    }
    // A plain colour stays a string, anything more is an object: the v2 grammar
    // ("blend:multiply:adaptive:h,l,s,a") makes Qt.color() return invalid and stops
    // the settings window rendering. The halo belongs to the entry, not a layer.
    function layerValue() {
        if (sourceMode === "colour" && layerOpacity >= 1 && layerPhase <= 0
            && blendMode === "normal" && layerMask === "all" && layerSpace === "window")
            return current.toString()
        const o = ({ colour: colour1.toString() })
        if (blendMode !== "normal") o.blend = blendMode
        if (layerOpacity < 1) o.opacity = Number(layerOpacity.toFixed(2))
        if (layerPhase > 0) o.phase = Number(layerPhase.toFixed(2))
        if (layerMask !== "all") {
            o.mask = layerMask; o.maskDist = Number(layerMaskDist.toFixed(1))
            if (layerMaskSoft > 0) o.maskSoft = Number(layerMaskSoft.toFixed(1))
        }
        if (layerSpace !== "window") o.space = layerSpace
        if (styled) {
            o.source = sourceMode
            o.params = ({ speed: Number(stSpeed.toFixed(2)), scale: Number(stScale.toFixed(2)),
                          angle: Math.round(stAngle), colours: liveStops })
            if (Theme.fillImage(sourceMode)) o.params.src = stSrc
            // A kind's own options ride back out, including ones this build has
            // no controls for, so opening a role here cannot flatten what a
            // later build wrote.
            for (const k in stOwn) o.params[k] = stOwn[k]
        }
        if (sourceMode === "adaptive") {
            o.source = "adaptive"
            o.amounts = ({ hue: Number(adHue.toFixed(2)), lum: Number(adLum.toFixed(2)),
                           sat: Number(adSat.toFixed(2)), opacity: Number(adOpacity.toFixed(2)) })
        }
        if (isFilterKind) {
            o.source = sourceMode
            o.params = ({})
            for (const k in stOwn) o.params[k] = stOwn[k]
        }
        return o
    }
    // The whole entry: the stack, written flat when it has one layer, with the entry's
    // halo and swatch stamp put back around it. Blend rides on each layer; the bottom
    // layer's is the entry's (BlendSurface reads it through Theme.blendOf).
    function entryOf(ls) {
        const eff = (originalRaw !== null && typeof originalRaw === "object" && originalRaw.effect)
                    ? originalRaw.effect : undefined
        const fr = entryFrom.length > 0 ? entryFrom : undefined
        if (ls.length === 0) return "#00000000"
        if (ls.length === 1) {
            const v = ls[0]
            if (eff === undefined && fr === undefined) return v
            const o = typeof v === "string" ? ({ colour: v }) : Object.assign({}, v)
            if (eff !== undefined) o.effect = eff
            if (fr !== undefined) o.from = fr
            return o
        }
        const o = ({ layers: ls })
        if (eff !== undefined) o.effect = eff
        if (fr !== undefined) o.from = fr
        return o
    }
    function currentValue() { return entryOf(layerEntries()) }
    // What the interface shows while the picker is open. A muted layer is
    // missing from this and present in what is committed: it is a way of
    // seeing what a layer does, not an edit.
    function previewValue() {
        // A/B: what was there when this opened, on the real surface rather
        // than in a 20px swatch. `originalRaw` is kept for Cancel anyway —
        // this only makes it visible.
        if (comparing) return originalRaw
        return entryOf(layerEntries().filter((e, i) => layerShown(i)))
    }
    property bool comparing: false
    // The theme swatch this role uses, if any; drawing ignores it. The shelf uses it
    // to follow swatch changes, so a hand edit here clears it. A personal-shelf
    // swatch is applied by value and never stamps.
    property string entryFrom: ""
    function applySwatch(id, entry, stamp) {
        loading = true
        hexInput.focus = false
        layers = (entry !== null && typeof entry === "object" && Theme.isList(entry.layers) && entry.layers.length)
                 ? Array.prototype.slice.call(entry.layers) : [entry]
        muted = layers.map(() => false)
        layerAt = advanced ? 0 : firstDyeable()
        loadLayer(layers[layerAt])
        syncHex(true); livePreview()
        entryFrom = stamp === false ? "" : String(id)
        loading = false
    }
    onComparingChanged: if (previewCb) previewCb(previewValue())
    // Coalesced: a drag across the SV square emits a change per mouse move,
    // and repainting the whole interface that often is wasted work even when
    // nothing is written to disk.
    Timer {
        id: previewTick
        interval: 30
        onTriggered: if (picker.previewCb) picker.previewCb(picker.previewValue())
    }
    function livePreview() {
        if (!loading) entryFrom = ""   // an edit by hand: no longer the swatch's
        syncHex(); if (previewCb) previewTick.restart()
    }
    // Drop the code box's focus before syncing: syncHex skips a focused field, and
    // editingFinished would re-apply the pasted text when focus finally left.
    function fromLever() { hexInput.focus = false; syncHex(true); livePreview() }

    function accept() {
        picker.close()
        const f = cb; cb = null
        if (!f) return
        const v = currentValue()
        remember(v)
        f(v)
    }
    function reject() {
        picker.close()
        previewTick.stop()
        // Put back what was showing before the picker opened. The commit
        // callback never ran, so this is the only thing that changed.
        if (previewCb) previewCb(originalRaw)
        previewCb = null
        cb = null
    }
    // #RRGGBB, or #AARRGGBB with alpha (Qt's order, which Copy writes, so a Paste
    // lands here); opaque colours stay six digits. `force` for a load: the field may
    // still have focus from the previous entry, and the guard below would keep that
    // entry's colour in the box.
    function hexOf(c) { return c.toString() }
    // A colour or null. Qt.color() on a string that is not a colour warns and
    // comes back invalid, so what can be one is decided here first.
    function hexTo(t) {
        if (!/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(t)) return null
        return Qt.color(t)
    }
    function syncHex(force) {
        if (!force && hexInput.activeFocus) return   // the field is being typed in
        hexInput.text = hexOf(current)
        hexInput.cursorPosition = 0
    }
    // A hidden editor IS the clipboard: QML has none of its own, and WindowCtl
    // only writes to it.
    TextEdit { id: clip; visible: false; width: 0; height: 0 }
    function copyEntry() {
        const v = currentValue()
        clip.text = typeof v === "string" ? v : Theme.entryToCode(v)
        clip.selectAll(); clip.copy(); clip.deselect()
    }
    function pasteEntry() {
        clip.text = ""
        clip.paste()
        if (applyText(clip.text)) { syncHex(true); livePreview() }
    }
    // A bare hex dyes, a code replaces. Typing a colour into a box surrounded
    // by a fill's controls changes the colour and keeps the fill. A whole code
    // sets everything; it arrives by Paste rather than by typing.
    function applyText(text) {
        let t = String(text).trim()
        if (t.length > 0 && t[0] !== "#" && /^[0-9a-f]/i.test(t)) t = "#" + t
        // Length tells them apart. Both start with '#', and the longest colour
        // a person types is #AARRGGBB, nine characters, so anything longer
        // is a code and anything up to it is the colour on the wheel: the
        // selected stop's, or the layer's own.
        if (t.length <= 9) {
            const hc = hexTo(t)
            if (hc === null) return false
            loadOnWheel(hc)
            entryFrom = ""   // typed: the role's own, as an edit by hand is
            syncHex()   // a no-op while the field has focus, which is while it is typed in
            return true
        }
        const v = Theme.codeToEntry(t)
        if (v === null) return false
        if (typeof v === "string") {
            const c = Qt.color(v); if (c.valid === false) return false
            loadOnWheel(c)
            entryFrom = ""   // typed or pasted: the role's own, as an edit by hand is
            syncHex()   // a no-op while the field has focus, which is while it is typed in
            return true
        }
        const was = loading
        loading = true
        const ls = Theme.isList(v.layers) && v.layers.length ? Array.prototype.slice.call(v.layers) : [v]
        layers = ls; layerAt = 0; muted = ls.map(() => false)
        loadLayer(ls[0])
        if (v.effect !== undefined)
            originalRaw = Object.assign({}, typeof originalRaw === "object" && originalRaw ? originalRaw : {},
                                        ({ effect: v.effect }))
        loading = was
        entryFrom = ""
        syncHex()
        return true
    }

    function open(entry, ctx) {
        picker.load(entry, ctx)
        // the size it was left at, else what this entry's controls need
        // (no Settings in a standalone test run: the natural size, then)
        const kept = typeof Settings !== "undefined" ? Settings.uiGet("colourPickerSize", null) : null
        width = kept && kept.w > 0 ? Math.max(minimumWidth, kept.w)
                                   : Math.round(Theme.sp(picker.showSources ? 460 : 340))
        userSized = kept && kept.h > 0
        if (userSized) height = Math.max(minimumHeight, kept.h)
        else fitHeight()
        applyGlass()
        visible = true
        requestActivate()
    }
    // Follows its content until the user resizes it. A width set in open() does not
    // reach the gallery until the next polish, so one measurement comes back a column
    // too narrow and too tall; the content signals when it has settled and the window
    // re-fits, which also grows it when an entry gains a palette.
    property bool userSized: false
    // What we last asked for, not a flag around the assignment. A window's
    // height is set through the platform and comes back as a resize event, so
    // the notification lands well after any flag has been cleared, and every
    // fit would be read as someone dragging the frame.
    property real fitted: -1
    function fitHeight() {
        fitted = Math.max(minimumHeight, Math.round(titleBar.height + dialog.fullHeight))
        height = fitted
    }
    function applyGlass() {
        if (typeof WindowCtl === "undefined") return   // a standalone test run
        const on = Theme.glassBlur !== "off" && Theme.translucent("window")
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(picker, on)
    }
    // Coalesced: a drag on the frame resizes per motion event, and the point
    // is the size it is let go at.
    onWidthChanged: if (visible) sizeKeep.restart()
    onHeightChanged: {
        if (visible && Math.abs(height - fitted) > 1) userSized = true   // a drag on the frame
        if (visible) sizeKeep.restart()
    }
    Timer {
        id: sizeKeep
        interval: 400
        onTriggered: if (typeof Settings !== "undefined")
                         Settings.uiSet("colourPickerSize", ({ w: Math.round(picker.width),
                                                               // only a height someone chose: one this
                                                               // fitted would stop it fitting again
                                                               h: picker.userSized ? Math.round(picker.height) : 0 }))
    }
    onVisibleChanged: Theme.previewing += visible ? 1 : -1
    // A popup does not dismiss itself: it is its own window, so a click inside
    // this one is not an outside click as far as the popup grab is concerned.
    // This eats the first press anywhere while it is open, as a menu does, and
    // losing focus closes it too.
    MouseArea {
        anchors.fill: parent
        z: 500
        visible: pickerMenu.visible
        onPressed: pickerMenu.close()
    }
    // a grace period: opening the popup itself shuffles activation
    onActiveChanged: if (!active && pickerMenu.visible
                         && Date.now() - pickerMenu.openedAt > 200) pickerMenu.close()
    // The window this was opened from closing takes it along, with the
    // preview put back — an orphan picker over the main window commits to a
    // settings page nobody can see.
    Connections {
        target: picker.visible ? picker.transientParent : null
        function onVisibleChanged() { if (!picker.transientParent.visible) picker.reject() }
    }

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.height
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Theme.windowRadius; bottomRightRadius: Theme.windowRadius
        visible: Theme.hasPage
    }
    Surface {   // the window border, above the title bar, as in the other windows
        anchors.fill: parent
        role: ""
        radius: Theme.windowRadius
        borderRole: "windowBorder"
        borderWidth: Theme.windowBorderWidth
        visible: Theme.windowBorder
        z: 1000
    }
    Surface {   // title bar
        id: titleBar
        width: parent.width
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Theme.windowRadius
        topRightRadius: Theme.windowRadius
        MouseArea { anchors.fill: parent; onPressed: picker.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left; anchors.leftMargin: Theme.inset("title", "left")
            text: "Colour"
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightMedium }
        }
        Row {
            id: modeRow
            objectName: "pickerMode"
            anchors.right: closeBtn.left; anchors.rightMargin: Theme.gap(6)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            spacing: Theme.gap(3)
            // hidden where Simple could not edit the entry anyway
            visible: picker.canDye
            Repeater {
                model: ["simple", "advanced"]
                Surface {
                    required property string modelData
                    objectName: "pickerMode_" + modelData
                    readonly property bool on: picker.advanced === (modelData === "advanced")
                    width: Theme.ctl(52); height: Theme.ctl(16)
                    radius: Theme.radiusSm
                    role: on ? "accent" : Theme.faceOf("segment", mMa.containsMouse)
                    Text {
                        anchors.centerIn: parent
                        text: parent.modelData
                        color: parent.on ? Theme.onFill(parent.color) : Theme.textDim
                        font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                    }
                    MouseArea { id: mMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: picker.setAdvanced(parent.modelData === "advanced") }
                }
            }
        }
        Item {
            id: closeBtn
            anchors.right: parent.right; anchors.rightMargin: Theme.inset("title", "right")
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            width: Theme.ctl(26); height: Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                ink: closeMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: closeMa.containsMouse; pressed: closeMa.pressed
                frameWidth: Theme.iconBtn; frameHeight: Math.min(Theme.iconBtn, Theme.ctl(20) + Theme.inset("title", "top") + Theme.inset("title", "bottom")) }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: picker.reject() }
        }
    }

    // Everything below the title bar. Only a container: the picker's own
    // state is on the window, which is what a call site holds.
    Item {
        id: body
        objectName: "pickerBody"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: titleBar.bottom; anchors.bottom: parent.bottom

    Item {
        id: dialog
        objectName: "colourPickerDialog"
        anchors.fill: parent
        readonly property real pad: Theme.inset("tool", "top")
        readonly property real padB: Theme.inset("tool", "bottom")
        readonly property real gap: Theme.gap(6)
        readonly property real logicalWidth: body.width
        // From the width, not the height. The height is derived from this, so
        // reading the height here would make the two define each other.
        readonly property bool compact: body.width < Theme.sp(420)
        // What everything needs, which is what the window is asked to be —
        // and NOT what the body has, which is whatever is left after the
        // footer once someone has dragged the window taller.
        readonly property real bodyNeeds: Math.max(layerPane.implicitHeight,
            picker.showSources ? railRows.implicitHeight + Theme.gap(8) + railTools.implicitHeight : 0)
        readonly property real fullHeight: bodyNeeds + footer.height + gap + pad + padB
        onFullHeightChanged: if (picker.visible && !picker.userSized) picker.fitHeight()

        // Anchored, not a column: the window can be dragged taller, and the footer
        // belongs at the bottom with the body taking what is between.
        Item {
            id: pickCol
            anchors.fill: parent
            anchors.leftMargin: Theme.inset("tool", "left"); anchors.rightMargin: Theme.inset("tool", "right")
            anchors.topMargin: dialog.pad; anchors.bottomMargin: dialog.padB

            // Colour and adjustment controls share a row; the footer is outside both. The
            // stack goes down the left, top layer first, since upper rows draw over lower
            // ones; the selected layer's properties, colour included, go down the right.
            Item {
                id: editorBody
                objectName: "pickerEditor"
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: footer.top
                anchors.bottomMargin: dialog.gap
                readonly property real railW: picker.showSources ? Theme.sp(112) : 0

                // Stack actions sit at the foot of the rail, where they stay put while layers
                // are added and removed.
                Item {
                    id: layerRail
                    objectName: "pickerLayers"
                    width: editorBody.railW
                    height: editorBody.height
                    visible: picker.showSources
                    Column {
                        id: railRows
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: Theme.gap(2)
                        Repeater {
                            model: picker.layerCount
                            Item {
                                id: lrow
                                required property int index
                                // the format is bottom-to-top; the list is not
                                readonly property int at: picker.layerCount - 1 - index
                                objectName: "pickerLayer_" + at
                                readonly property bool on: picker.layerAt === at
                                readonly property bool off: !picker.layerShown(at)
                                width: railRows.width
                                height: Theme.ctl(24)
                                // A selected row is the selected surface only, as in every melo
                                // list; the theme decides the look.
                                Surface {
                                    anchors.fill: parent
                                    radius: Theme.radiusSm
                                    role: lrow.on ? "selected" : (lrowMa.containsMouse ? "hover" : "")
                                }
                                EntryChip {
                                    id: lface
                                    anchors.left: parent.left; anchors.leftMargin: Theme.gap(3)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(26); height: Theme.ctl(16)
                                    entry: lrow.on ? picker.layerValue() : picker.layers[lrow.at]
                                    // a filter is shown over what it filters
                                    under: lrow.at > 0 ? picker.layerEntries()[lrow.at - 1] : null
                                    fallback: picker.colour1
                                    opacity: lrow.off ? 0.25 : 1
                                }
                                InkText {
                                    anchors.left: lface.right; anchors.leftMargin: Theme.gap(5)
                                    anchors.right: lmute.left; anchors.rightMargin: Theme.gap(4)
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: Theme.sourceName(Theme.sourceOf(
                                        lrow.on ? picker.layerValue() : picker.layers[lrow.at]))
                                    ink: lrow.on ? "text" : "textDim"
                                    opacity: lrow.off ? 0.4 : 1
                                    font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                                }
                                MouseArea {
                                    id: lrowMa
                                    anchors.fill: parent; hoverEnabled: true
                                    onClicked: picker.selectLayer(lrow.at)
                                }
                                Rectangle {
                                    id: lmute
                                    objectName: "pickerLayerMute_" + lrow.at
                                    visible: picker.layerCount > 1
                                    anchors.right: parent.right; anchors.rightMargin: Theme.gap(5)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(7); height: width; radius: width / 2
                                    color: lrow.off ? "transparent"
                                         : (picker.soloAt === lrow.at ? Theme.accent : Theme.textDim)
                                    border.color: Theme.border
                                    MouseArea {
                                        anchors.fill: parent; anchors.margins: -Theme.gap(4)
                                        onClicked: picker.toggleMute(lrow.at)
                                    }
                                }
                            }
                        }
                    }
                    Column {
                        id: railTools
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: Theme.gap(2)
                        Row {
                            objectName: "pickerLayerTools"
                            width: railRows.width
                            spacing: Theme.gap(3)
                            component LTool: Rectangle {
                                id: lt
                                property string glyph
                                property bool on: true
                                signal go()
                                // nothing to add, drop, move or solo: the face
                                // stays flat, because one that lights up under
                                // the pointer promises a press that does nothing
                                readonly property bool hovered: lt.on && ltMa.containsMouse
                                readonly property bool held: lt.on && ltMa.pressed
                                width: (railTools.width - Theme.gap(12)) / 5
                                height: Theme.ctl(20)
                                radius: Theme.radiusSm
                                color: Theme[Theme.faceOf("button", hovered, held)]
                                border.color: hovered ? Theme.borderStrong : Theme.border
                                opacity: on ? 1 : 0.4
                                InkText { anchors.centerIn: parent; text: lt.glyph; ink: "textDim"
                                       anchors.horizontalCenterOffset: Theme.pressShift(lt.held)
                                       anchors.verticalCenterOffset: Theme.pressShift(lt.held)
                                       font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                                MouseArea { id: ltMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: if (lt.on) lt.go() }
                            }
                            LTool { objectName: "pickerLayerAdd"; glyph: "+"; onGo: picker.addLayer() }
                            LTool { objectName: "pickerLayerDrop"; glyph: "\u2212"
                                    on: picker.layerCount > 1; onGo: picker.removeLayer() }
                            // up the list is up the stack: the arrows mean what
                            // they point at
                            LTool { objectName: "pickerLayerUp"; glyph: "\u25b2"
                                    on: picker.layerAt < picker.layerCount - 1; onGo: picker.moveLayer(1) }
                            LTool { objectName: "pickerLayerDown"; glyph: "\u25bc"
                                    on: picker.layerAt > 0; onGo: picker.moveLayer(-1) }
                            LTool { objectName: "pickerLayerSolo"; glyph: "\u25c9"
                                    on: picker.soloAt === picker.layerAt; onGo: picker.toggleSolo() }
                        }
                        InkText {
                            objectName: "pickerCost"
                            width: railRows.width
                            horizontalAlignment: Text.AlignRight
                            visible: picker.layerCount > 1
                            text: Theme.stackPasses(picker.currentValue()) + " passes"
                            ink: "textFaint"
                            font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                        }
                    }
                }

                Column {
                    id: layerPane
                    x: editorBody.railW + (picker.showSources ? Theme.gap(10) : 0)
                    width: parent.width - x
                    spacing: dialog.gap


                            // ---- this layer's fill: what it is, and the way to change it ----
                            Surface {
                                id: fillRow
                                objectName: "pickerFill"
                                width: parent.width
                                height: Theme.ctl(28)
                                radius: Theme.radiusSm
                                role: Theme.faceOf("button", fillMa.containsMouse, fillMa.pressed)
                                borderWidth: 1
                                borderRole: fillSelect.visible ? "accent"
                                          : fillMa.containsMouse ? "borderStrong" : "border"
                                visible: picker.showSources
                                readonly property int shift: Theme.pressShift(fillMa.pressed)
                                EntryChip {
                                    id: fillFace
                                    anchors.left: parent.left; anchors.leftMargin: Theme.gap(5) + fillRow.shift
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(34); height: Theme.ctl(18)
                                    entry: picker.layerValue()
                                    under: picker.layerAt > 0 ? picker.layerEntries()[picker.layerAt - 1] : null
                                    fallback: picker.colour1
                                }
                                InkText {
                                    objectName: "pickerFillName"
                                    anchors.left: fillFace.right; anchors.leftMargin: Theme.gap(8)
                                    anchors.right: fillCog.visible ? fillCog.left : fillArrow.left
                                    anchors.rightMargin: Theme.gap(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: fillRow.shift
                                    elide: Text.ElideRight
                                    text: Theme.sourceName(picker.sourceMode)
                                    ink: "text"
                                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                                }
                                Text {
                                    id: fillArrow
                                    anchors.right: parent.right; anchors.rightMargin: Theme.gap(8) - fillRow.shift
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: fillRow.shift
                                    text: "\u203a"
                                    color: Theme.textDim
                                    font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
                                }
                                MouseArea {
                                    id: fillMa
                                    anchors.fill: parent; hoverEnabled: true
                                    onClicked: fillSelect.visible ? fillSelect.visible = false : fillSelect.openBeside()
                                }
                                // Only where there is something to set. Most kinds have only
                                // the three levers every kind understands, and a button that
                                // opens an empty window is worse than no button.
                                Surface {
                                    id: fillCog
                                    objectName: "pickerFillSettings"
                                    visible: Theme.fillOptions(picker.sourceMode).length > 0
                                    anchors.right: fillArrow.left; anchors.rightMargin: Theme.gap(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(22); height: Theme.ctl(20)
                                    radius: Theme.radiusSm
                                    role: Theme.faceOf("button", cogMa.containsMouse, cogMa.pressed)
                                    borderWidth: 1
                                    borderRole: fillSettings.visible ? "accent"
                                              : cogMa.containsMouse ? "borderStrong" : "border"
                                    Icon { anchors.centerIn: parent; name: "settings"; size: Theme.glyph(11)
                                           anchors.horizontalCenterOffset: Theme.pressShift(cogMa.pressed)
                                           anchors.verticalCenterOffset: Theme.pressShift(cogMa.pressed)
                                           ink: "textDim" }
                                    MouseArea {
                                        id: cogMa
                                        anchors.fill: parent; hoverEnabled: true
                                        onClicked: fillSettings.visible ? fillSettings.visible = false
                                                                        : fillSettings.openBeside()
                                    }
                                }
                            }

                    // ---- SV square: hue base + white->transparent + transparent->black ----
                    Rectangle {
                        id: svBox
                        objectName: "saturationValue"
                        visible: picker.needsColour
                        width: parent.width
                        height: Theme.ctl(dialog.compact ? 72 : 104)
                        radius: Theme.radiusSm
                        color: Qt.hsva(picker.hue, 1, 1, 1)
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#ffffff" }
                                GradientStop { position: 1.0; color: "transparent" }
                            }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: "#000000" }
                            }
                        }
                        Rectangle {   // cursor ring
                            x: picker.sat * parent.width - 6
                            y: (1 - picker.val) * parent.height - 6
                            width: Theme.ctl(12); height: Theme.ctl(12); radius: 6
                            color: "transparent"
                            border.color: picker.val > 0.6 && picker.sat < 0.5 ? "#000000" : "#ffffff"
                            border.width: 2
                        }
                        MouseArea {
                            anchors.fill: parent
                            function pick(m) {
                                picker.sat = Math.max(0, Math.min(1, m.x / width))
                                picker.val = Math.max(0, Math.min(1, 1 - m.y / height))
                                picker.fromLever()
                            }
                            onPressed: (m) => pick(m)
                            onPositionChanged: (m) => { if (pressed) pick(m) }
                        }
                    }

                    // ---- hue strip ----
                    Rectangle {
                        objectName: "hueStrip"
                        visible: picker.needsColour
                        width: parent.width
                        height: Theme.ctl(14)
                        radius: Theme.radiusSm
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0/6;   color: "#ff0000" }
                            GradientStop { position: 1/6;   color: "#ffff00" }
                            GradientStop { position: 2/6;   color: "#00ff00" }
                            GradientStop { position: 3/6;   color: "#00ffff" }
                            GradientStop { position: 4/6;   color: "#0000ff" }
                            GradientStop { position: 5/6;   color: "#ff00ff" }
                            GradientStop { position: 1.0;   color: "#ff0000" }
                        }
                        Rectangle {   // cursor
                            x: picker.hue * parent.width - 2
                            width: 4; height: parent.height
                            color: "transparent"
                            border.color: "#ffffff"; border.width: 1.5
                        }
                        MouseArea {
                            anchors.fill: parent
                            function pick(m) {
                                picker.hue = Math.max(0, Math.min(0.999, m.x / width))
                                picker.fromLever()
                            }
                            onPressed: (m) => pick(m)
                            onPositionChanged: (m) => { if (pressed) pick(m) }
                        }
                    }

                    // ---- alpha strip ----
                    Item {
                        objectName: "alphaStrip"
                        visible: picker.needsColour
                        width: parent.width
                        height: Theme.ctl(14)
                        InkText {
                            id: alphaPct
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: Math.round(picker.alpha * 100) + "%"
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        Checker { anchors.fill: parent; anchors.rightMargin: alphaPct.width + Theme.gap(8) }
                        Rectangle {
                            id: alphaBar
                            anchors.fill: parent
                            anchors.rightMargin: alphaPct.width + Theme.gap(8)
                            radius: Theme.radiusSm
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: Qt.rgba(picker.opaque.r, picker.opaque.g, picker.opaque.b, 0) }
                                GradientStop { position: 1.0; color: Qt.rgba(picker.opaque.r, picker.opaque.g, picker.opaque.b, 1) }
                            }
                        }
                        Rectangle {   // cursor
                            x: alphaBar.x + picker.alpha * alphaBar.width - 2
                            width: 4; height: parent.height
                            color: "transparent"
                            border.color: "#ffffff"; border.width: 1.5
                        }
                        MouseArea {
                            anchors.fill: alphaBar
                            function pick(m) {
                                picker.alpha = Math.max(0, Math.min(1, m.x / width))
                                picker.fromLever()
                            }
                            onPressed: (m) => pick(m)
                            onPositionChanged: (m) => { if (pressed) pick(m) }
                        }
                    }
                    Surface {   // the colour as hex, beside the colour it is
                        // ...and gone where there is no colour: a rainbow, an
                        // adaptive surface and a filter have none
                        visible: picker.needsColour
                        width: parent.width
                        height: Theme.ctl(24)
                        radius: Theme.radiusMd
                        role: "input"
                        borderWidth: 1
                        borderRole: hexInput.activeFocus ? "borderStrong" : "border"
                        TextInput {
                            id: hexInput
                            objectName: "pickerCode"
                            anchors.fill: parent
                            anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.text
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            clip: true
                            selectByMouse: true
                            onTextEdited: if (!picker.loading && picker.applyText(text)) picker.livePreview()
                            onEditingFinished: {
                                if (picker.loading) return
                                // not fromLever: focus is already leaving, and taking
                                // it again here would emit editingFinished a second time
                                if (picker.applyText(text)) { picker.syncHex(true); picker.livePreview() }
                                else picker.syncHex()
                            }
                            Keys.onReturnPressed: picker.accept()
                            Keys.onEscapePressed: picker.reject()
                        }
                    }

                    EntryChip {
                        width: parent.width; height: Theme.ctl(100)
                        visible: !picker.needsColour
                        entry: picker.currentValue()
                        fallback: picker.colour1
                    }

                    // ---- the picture, for the image fill ----
                    Row {
                        width: parent.width
                        spacing: Theme.gap(8)
                        visible: (picker.blendable || picker.adaptable) && Theme.fillImage(picker.sourceMode)
                        PushButton {
                            width: Theme.ctl(80)
                            label: "Choose…"
                            onClicked: Portal.openFile("picker-image", "Choose image", "Images",
                                                       ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif"], false)
                        }
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.ctl(80) - Theme.gap(8)
                            elide: Text.ElideMiddle
                            text: picker.stSrc.length > 0 ? decodeURIComponent(picker.stSrc.split("/").pop()) : ""
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                    }
                    Connections {
                        target: typeof Portal !== "undefined" ? Portal : null
                        function onPicked(tag, paths) {
                            if (tag !== "picker-image" || paths.length === 0) return
                            const p = String(paths[0])
                            picker.stSrc = p.startsWith("file:") ? p : "file://" + p
                            picker.livePreview()
                        }
                    }

                            // ---- which colour the wheel edits: the base, then the palette's stops ----
                            Flow {
                                id: palette
                                objectName: "paletteStops"
                                width: parent.width
                                spacing: Theme.gap(4)
                                visible: picker.advanced && picker.twoColours
                                readonly property int tools: (picker.hasPalette && picker.stops.length < 6 ? 1 : 0)
                                                           + (picker.hasPalette && picker.editing >= 0 ? 3 : 0)
                                readonly property real swatchW: Math.min(Theme.ctl(40),
                                    (width - tools * Theme.ctl(24) - Math.max(0, picker.colourCount + tools - 1) * spacing) / Math.max(1, picker.colourCount))
                                component Swatch: Rectangle {
                                    property int at: -1
                                    property string tag: ""
                                    readonly property bool on: picker.editing === at
                                    width: parent.swatchW; height: Theme.ctl(24)
                                    radius: Theme.radiusSm
                                    color: at < 0 ? picker.colour1 : picker.stopColour(at)
                                    border.color: on ? Theme.accent : Theme.border
                                    border.width: on ? 2 : 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.tag
                                        color: Theme.onFill(parent.color)
                                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily; weight: Theme.weightMedium }
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: picker.editColour(parent.at) }
                                }
                                Swatch { visible: picker.hasBase; at: -1; tag: "base" }
                                Repeater {
                                    model: picker.stops.length
                                    Swatch { required property int index; at: index; tag: String(index + 1) }
                                }
                                component Tool: Rectangle {
                                    id: tool
                                    property string glyph
                                    signal go()
                                    // a stop at the end of the row has nowhere
                                    // to move: no hover, no press, no sink
                                    readonly property bool hovered: tool.enabled && tMa.containsMouse
                                    readonly property bool held: tool.enabled && tMa.pressed
                                    width: Theme.ctl(24); height: Theme.ctl(24)
                                    radius: Theme.radiusSm
                                    color: Theme[Theme.faceOf("button", hovered, held)]
                                    border.color: hovered ? Theme.borderStrong : Theme.border
                                    InkText { anchors.centerIn: parent; text: tool.glyph; ink: "textDim"
                                           anchors.horizontalCenterOffset: Theme.pressShift(tool.held)
                                           anchors.verticalCenterOffset: Theme.pressShift(tool.held)
                                           font { pixelSize: Theme.fs(13); family: Theme.fontFamily } }
                                    opacity: enabled ? 1 : 0.4
                                    MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; onClicked: tool.go() }
                                }
                                Tool {
                                    objectName: "stopLeft"
                                    visible: picker.hasPalette && picker.editing >= 0
                                    enabled: picker.editing > 0
                                    glyph: "◀"; onGo: picker.moveStop(-1)
                                }
                                Tool {
                                    objectName: "stopRight"
                                    visible: picker.hasPalette && picker.editing >= 0
                                    enabled: picker.editing >= 0 && picker.editing < picker.stops.length - 1
                                    glyph: "▶"; onGo: picker.moveStop(1)
                                }
                                Tool { visible: picker.hasPalette && picker.stops.length < 6; glyph: "+"; onGo: picker.addStop() }
                                Tool { visible: picker.hasPalette && picker.editing >= 0; glyph: "−"; onGo: picker.removeStop() }
                            }

            // ---- a fill's levers ----
                    Column {
                        width: parent.width
                        spacing: Theme.gap(4)
                        visible: picker.showSources && picker.levers.length > 0
                        Repeater {
                            model: picker.levers
                            Item {
                                id: stRow
                                required property var modelData
                                objectName: "pickerLever_" + modelData.key
                                readonly property real amount: modelData.inverse ? 1 / picker[modelData.key] : picker[modelData.key]
                                function apply(v) { picker[modelData.key] = modelData.inverse ? 1 / v : v; picker.livePreview() }
                                width: parent.width
                                height: Theme.ctl(24)
                                InkText {
                                    id: stName
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    text: stRow.modelData.label
                                    ink: "textDim"
                                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                                }
                                InkText {
                                    id: stVal
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.right: parent.right
                                    width: Theme.gap(34)
                                    horizontalAlignment: Text.AlignRight
                                    text: stRow.modelData.key === "stSpeed" && stRow.amount === 0 ? "still"
                                        : stRow.modelData.key === "stAngle" ? Math.round(stRow.amount) + "°" : stRow.amount.toFixed(2)
                                    ink: "textDim"
                                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                                }
                                MSlider {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: stName.right
                                    anchors.leftMargin: Theme.gap(8)
                                    anchors.right: stVal.left
                                    anchors.rightMargin: Theme.gap(8)
                                    from: stRow.modelData.from
                                    to: stRow.modelData.to
                                    step: stRow.modelData.step
                                    value: stRow.amount
                                    onLiveChanged: stRow.apply(live)
                                    onCommitted: (v) => stRow.apply(v)
                                }
                            }
                        }
                    }

                    // ---- what the pattern is anchored to. Only for a kind that has
                    // a pattern: a flat colour and a contrast look the same wherever
                    // they are measured from.
                    Item {
                        objectName: "pickerSpace"
                        width: parent.width
                        height: Theme.ctl(24)
                        visible: picker.advanced && picker.styled && !(picker.sourceMode === "image" && picker.imageFit === 5)
                        InkText {
                            id: spName
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.gap(50)
                            text: "space"
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        Row {
                            anchors.left: spName.right
                            anchors.leftMargin: Theme.gap(8)
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(3)
                            Repeater {
                                model: Theme.fillSpaces
                                Surface {
                                    required property string modelData
                                    objectName: "pickerSpace_" + modelData
                                    readonly property bool on: picker.layerSpace === modelData
                                    width: (parent.width - Theme.gap(6)) / 3; height: Theme.ctl(20)
                                    radius: Theme.radiusSm
                                    role: on ? "accent" : Theme.faceOf("segment", spMa.containsMouse)
                                    borderWidth: 1; borderRole: on ? "accent" : "border"
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.modelData
                                        color: parent.on ? Theme.onFill(parent.color) : Theme.textDim
                                        font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                                    }
                                    MouseArea {
                                        id: spMa
                                        anchors.fill: parent; hoverEnabled: true
                                        onClicked: { picker.layerSpace = parent.modelData; picker.livePreview() }
                                    }
                                }
                            }
                        }
                    }

                    // ---- where this layer draws: all of the shape, a band at its
                    // edge, or everything inside that band. The distance is measured
                    // from the drawn coverage, so it follows a glyph or a rounded
                    // corner rather than the item's rectangle.
                    Item {
                        objectName: "pickerMask"
                        width: parent.width
                        height: Theme.ctl(24)
                        visible: picker.advanced && picker.showSources
                        InkText {
                            id: mkName
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.gap(50)
                            text: "mask"
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        Row {
                            anchors.left: mkName.right
                            anchors.leftMargin: Theme.gap(8)
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(3)
                            Repeater {
                                model: Theme.maskModes
                                Surface {
                                    required property string modelData
                                    objectName: "pickerMask_" + modelData
                                    readonly property bool on: picker.layerMask === modelData
                                    width: (parent.width - Theme.gap(6)) / 3
                                    height: Theme.ctl(20)
                                    radius: Theme.radiusSm
                                    role: on ? "accent" : Theme.faceOf("segment", mkMa.containsMouse)
                                    borderWidth: 1; borderRole: on ? "accent" : "border"
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.modelData
                                        color: parent.on ? Theme.onFill(parent.color) : Theme.textDim
                                        font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                                    }
                                    MouseArea {
                                        id: mkMa
                                        anchors.fill: parent; hoverEnabled: true
                                        onClicked: { picker.layerMask = parent.modelData; picker.livePreview() }
                                    }
                                }
                            }
                        }
                    }

                    // ---- blend, as a select: the list is too long for a row of chips.
                    // The call site says whether the entry may blend against what is behind it; a
                    // layer above the bottom blends against the layers under it instead.
                    Item {
                        objectName: "pickerBlends"
                        width: parent.width
                        height: Theme.ctl(24)
                        // and a filter has no blend: it replaces what is under it
                        visible: (picker.blendable || picker.layerAt > 0) && !picker.isFilterKind
                        InkText {
                            id: blName
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.gap(50)
                            text: "blend"
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        Surface {
                            objectName: "pickerBlendSelect"
                            anchors.left: blName.right
                            anchors.leftMargin: Theme.gap(8)
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: Theme.ctl(20)
                            radius: Theme.radiusSm
                            role: "input"
                            borderWidth: 1
                            borderRole: blMa.containsMouse ? "accent" : "border"
                            InkText {
                                anchors.left: parent.left; anchors.leftMargin: Theme.gap(8)
                                anchors.right: blArrow.left; anchors.rightMargin: Theme.gap(4)
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: picker.blendMode
                                ink: "text"
                                font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                            }
                            InkText {
                                id: blArrow
                                anchors.right: parent.right; anchors.rightMargin: Theme.gap(6)
                                anchors.verticalCenter: parent.verticalCenter
                                text: "\u25be"; ink: "textFaint"
                                font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                            }
                            MouseArea {
                                id: blMa
                                anchors.fill: parent; hoverEnabled: true
                                onClicked: {
                                    const p = blMa.mapToItem(null, 0, parent.height + 2)
                                    pickerMenu.openAt(picker, p.x, p.y, picker.blendChoices.map(m =>
                                        ({ label: m, act: () => { picker.blendMode = m; picker.livePreview() } })))
                                }
                            }
                        }
                    }



        
                }
            }

            // The code can pan horizontally while editing; the dialog itself
            // never scrolls, and confirmation stays beside the field.
            Row {
                id: footer
                objectName: "pickerFooter"
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: dialog.gap
            // the tools keep the right
            Item { width: parent.width - actions.width - dialog.gap; height: 1 }
            Row {
                id: actions
                spacing: Theme.gap(4)
                component Preview: Item {
                    property color show: "transparent"
                    width: Theme.ctl(20); height: Theme.btnH
                    Checker { anchors.fill: parent }
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusSm
                        color: parent.show
                        border.color: Theme.border
                    }
                }
                component CodeTool: PushButton {
                    id: ct
                    property string glyph
                    signal go()
                    width: Theme.ctl(24)
                    radius: Theme.radiusSm
                    label: ct.glyph; ink: "textDim"; fontSize: 12
                    onClicked: ct.go()
                }
                // The whole entry, where its length costs nothing: the box
                // beside these holds a colour, and a stack of fills with their
                // own options does not fit in a text box anyone can read.
                CodeTool { objectName: "pickerCopy"; glyph: "\u2398"; onGo: picker.copyEntry() }
                CodeTool { objectName: "pickerPaste"; glyph: "\u2399"; onGo: picker.pasteEntry() }
                // the swatch shelf: a stack is a lot of work to build, and this
                // moves one between roles
                CodeTool {
                    objectName: "pickerSwatches"
                    glyph: "\u25a4"
                    onGo: swatchShelf.visible ? swatchShelf.visible = false : swatchShelf.openBeside()
                }
                // Held, not toggled. Comparing is a glance, and a toggle you
                // can walk away from leaves the interface showing a value
                // nobody chose.
                Preview {
                    objectName: "pickerBefore"
                    show: picker.original
                    visible: picker.needsColour
                    MouseArea {
                        anchors.fill: parent
                        onPressed: picker.comparing = true
                        onReleased: picker.comparing = false
                        onCanceled: picker.comparing = false
                    }
                }
                Preview { objectName: "pickerAfter"; show: picker.current; visible: picker.needsColour }
                PushButton {
                    objectName: "pickerAccept"
                    width: Theme.ctl(44)
                    label: "OK"; accent: true; fontSize: 12
                    onClicked: picker.accept()
                }
            }
            }
        }
    }

    // The gallery, beside this rather than inside it: a window can host
    // another.
    // a menu of its own: the settings window's belongs to the settings window
    DropMenu { id: pickerMenu }
    FillSelect { id: fillSelect; objectName: "fillSelect"; picker: picker; transientParent: picker }
    FillSettings { id: fillSettings; objectName: "fillSettings"; picker: picker; transientParent: picker }
    SwatchShelf { id: swatchShelf; objectName: "swatchShelf"; picker: picker; transientParent: picker }
    onVisibleChanged: if (!visible) {
        fillSelect.visible = false; fillSettings.visible = false; swatchShelf.visible = false
    }

    Shortcut { sequence: "Escape"; enabled: picker.visible; onActivated: picker.reject() }
}
}
