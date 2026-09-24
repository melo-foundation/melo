import QtQuick
import QtQuick.Effects
import Melo 1.0
import ".."

// Theme background renderer. Reads Theme.background {type, gradient, src,
// opacity, blur, options{...}} and draws it behind the app content.
Item {
    id: root
    property var config: Theme.background
    readonly property string type: config.type || "none"
    readonly property real bgOpacity: config.opacity !== undefined ? config.opacity : 1
    readonly property real bgBlur: config.blur !== undefined ? config.blur : 0

    // MultiEffect's blurMax is in pixels, so the radius scales with the
    // rendered picture's short side; the stored setting keeps its 1080p meaning.
    readonly property real _blurRefPx: 1080
    // What we WANT, in pixels of the rendered background. Uncapped.
    readonly property real blurWantPx: {
        if (bgBlur <= 0) return 0
        const shortest = Math.min(Math.max(1, renderW), Math.max(1, renderH))
        return Math.max(1, bgBlur * shortest / _blurRefPx)
    }

    // The blur itself is MultiEffect up to 64px and a Kawase chain above (see the
    // split at imgBlur); this only has to say how wide.
    readonly property var opts: config.options || ({})
    // this instance renders the full window (false) or the mini bar (true)
    property bool miniMode: false
    // true during interactive move/resize: ALL repaint activity stops (same
    // discipline as the uiFrozen tick freeze — a canvas painting per resize
    // step causes the mid-resize jitter, and any activity in the sibling
    // window breaks KWin's commit/configure pairing)
    property bool hold: false
    // the pattern is drawn at renderW x renderH offset by renderX/Y inside the
    // (clipping) layer. Default = fill the layer. The mini bar sets these to
    // the FULL window size + a negative offset so it shows a pixel-identical
    // crop of the same render (viewport into the full-window pattern).
    property real renderW: width
    property real renderH: height
    property real renderX: 0
    property real renderY: 0
    // location + size: scale zooms the content, positionX/Y shift it (fraction
    // of the layer size, -0.5..0.5). Applied as a transform so root stays the
    // fixed clip window. When perModePosition is on, the mini instance reads
    // its own mini* values; otherwise both modes share scale/positionX/Y.
    readonly property bool _perMode: config.perModePosition === true && miniMode
    readonly property real cfgScale: _perMode ? (config.miniScale !== undefined ? config.miniScale : 1)
                                              : (config.scale !== undefined ? config.scale : 1)
    readonly property real cfgPosX: _perMode ? (config.miniPositionX !== undefined ? config.miniPositionX : 0)
                                             : (config.positionX !== undefined ? config.positionX : 0)
    readonly property real cfgPosY: _perMode ? (config.miniPositionY !== undefined ? config.miniPositionY : 0)
                                             : (config.positionY !== undefined ? config.positionY : 0)
    // The point of the picture kept when cropping; 0.5 is the centred crop.
    // Pan cannot choose it: it moves the frame, so past the edge it reveals the
    // layer behind rather than more picture.
    readonly property real cfgCropX: _perMode ? (config.miniCropX !== undefined ? config.miniCropX : 0.5)
                                              : (config.cropX !== undefined ? config.cropX : 0.5)
    readonly property real cfgCropY: _perMode ? (config.miniCropY !== undefined ? config.miniCropY : 0.5)
                                              : (config.cropY !== undefined ? config.cropY : 0.5)
    // Puts the picture's crop point in the middle of the frame, clamped to the
    // overflow so the picture still covers (or, for "contain", stays inside).
    // Interpolating by `over * point` agrees only at 0, 0.5 and 1.
    function cropOffset(box, drawn, point) {
        const over = box - drawn
        return Math.max(Math.min(0, over),
               Math.min(Math.max(0, over), box / 2 - point * drawn))
    }
    clip: true

    // Scale about the image point at the window centre, (0.5 - posX, 0.5 - posY),
    // so zooming keeps what Position brought into view; scaling about the image
    // centre pulls the middle back over it.
    readonly property real focusX: 0.5 - cfgPosX
    readonly property real focusY: 0.5 - cfgPosY

    // ---- image ----
    // The transform is on the box, not the picture, so the blur chain sees an
    // untransformed image and scale/pan apply to the blurred result; doing it
    // here rather than via layer.enabled allows a multi-pass effect.
    Item {
        id: imgBox
        x: root.renderX; y: root.renderY; width: root.renderW; height: root.renderH
        transform: [
            Scale { origin.x: root.focusX * imgBox.width; origin.y: root.focusY * imgBox.height
                    xScale: root.cfgScale; yScale: root.cfgScale },
            Translate { x: root.cfgPosX * imgBox.width; y: root.cfgPosY * imgBox.height }
        ]
        visible: root.type === "image" && img.source !== ""
        opacity: root.bgOpacity

        // The effects read this box-sized clip, not the picture: PreserveAspectCrop
        // discards the overflow the crop point chooses from, and a picture larger
        // than the effects' rect arrives squashed.
        // coverScale excludes cfgScale: zoom belongs to the frame transform, and
        // folding it in here leaves bare corners below zoom 1.
        Item {
            id: imgCrop
            anchors.fill: parent
            clip: true
            readonly property real srcW: Math.max(1, img.sourceSize.width)
            readonly property real srcH: Math.max(1, img.sourceSize.height)
            readonly property real coverScale: root.config.size === "contain"
                ? Math.min(width / srcW, height / srcH)
                : Math.max(width / srcW, height / srcH)
            // "stretch" is the one fit that does not preserve aspect: each
            // axis is scaled independently to land exactly on the frame. There
            // is then no overflow and no letterbox, so the crop point has
            // nothing to choose between and falls out at 0 on its own.
            readonly property bool stretch: root.config.size === "stretch"
            readonly property real drawW: stretch ? width : srcW * coverScale
            readonly property real drawH: stretch ? height : srcH * coverScale
            // layer.effect replaces this item's own drawing, so there is no
            // second copy to hide, and the transform on the parent applies to
            // the layer's result.
            layer.enabled: imgBox.smallBlur
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                // Full resolution: no layer.textureSize, which is the point.
                blurMax: Math.max(2, Math.min(64, Math.round(root.blurWantPx)))
            }
            Image {
                id: img
                source: root.type === "image" && root.config.src ? root.config.src : ""
                width: imgCrop.drawW
                height: imgCrop.drawH
                // already scaled to the exact size we want it drawn at
                fillMode: Image.Stretch
                x: root.cropOffset(imgCrop.width, width, root.cfgCropX)
                y: root.cropOffset(imgCrop.height, height, root.cfgCropY)
                asynchronous: true
                cache: true
            }
        }
        // Kawase halves resolution per level, which shows under a narrow blur, so
        // MultiEffect (full resolution, blurMax ceiling 64) takes radii up to 64px and
        // Kawase takes over above that.
        readonly property real kSmallBlur: 64
        readonly property bool wantBlur:
            (typeof MELO_HAS_GL === "undefined" || MELO_HAS_GL) && root.blurWantPx > 0.5
        readonly property bool smallBlur: wantBlur && root.blurWantPx <= kSmallBlur

        KawaseBlur {
            id: imgBlur
            anchors.fill: parent
            sourceItem: imgCrop
            // MultiEffect blurMax 64 looks like Kawase radius 43. They do not share units, so handing
            // Kawase the same number steps the moment it takes over.
            radius: (imgBox.wantBlur && !imgBox.smallBlur)
                    ? root.blurWantPx * (43 / 64) : 0
        }
    }

    // ---- gradient (parsed from a CSS linear-gradient string) ----
    // "linear-gradient(135deg, #a 0%, #b 100%)" -> QML LinearGradient stops.
    Rectangle {
        id: grad
        x: root.renderX; y: root.renderY; width: root.renderW; height: root.renderH
        transform: [
            Scale { origin.x: root.focusX * grad.width; origin.y: root.focusY * grad.height
                    xScale: root.cfgScale; yScale: root.cfgScale },
            Translate { x: root.cfgPosX * grad.width; y: root.cfgPosY * grad.height }
        ]
        visible: root.type === "gradient"
        opacity: root.bgOpacity
        gradient: Gradient {
            id: gg
            orientation: Gradient.Vertical
        }
        Component.onCompleted: root.applyGradient()
    }
    property var _gradStops: []
    function applyGradient() {
        if (type !== "gradient") return
        const parsed = parseCssGradient(String(config.gradient || ""))
        // rebuild GradientStop children
        for (const s of _gradStops) s.destroy()
        _gradStops = []
        gg.orientation = parsed.vertical ? Gradient.Vertical : Gradient.Horizontal
        for (const st of parsed.stops) {
            const o = Qt.createQmlObject(
                'import QtQuick; GradientStop { position: ' + st.pos + '; color: "' + st.color + '" }',
                gg)
            _gradStops.push(o)
        }
    }
    onConfigChanged: applyGradient()

    function parseCssGradient(s) {
        // pull the angle (deg) and the color stops; default top->bottom
        const inner = s.replace(/^.*linear-gradient\(/i, "").replace(/\)\s*$/, "")
        const parts = splitTopLevel(inner)
        let vertical = true
        let start = 0
        if (parts.length && /deg|to /i.test(parts[0])) {
            const m = parts[0].match(/([\d.]+)deg/)
            const deg = m ? Number(m[1]) : 180
            vertical = !(deg > 45 && deg < 135)   // ~horizontal vs ~vertical
            start = 1
        }
        const cs = parts.slice(start)
        const stops = []
        for (let i = 0; i < cs.length; i++) {
            const t = cs[i].trim()
            const pm = t.match(/(-?[\d.]+)%/)
            const color = t.replace(/\s*-?[\d.]+%\s*/, "").trim()
            const pos = pm ? Number(pm[1]) / 100 : (cs.length > 1 ? i / (cs.length - 1) : 0)
            if (color) stops.push({ pos: Math.max(0, Math.min(1, pos)), color: color })
        }
        if (!stops.length) stops.push({ pos: 0, color: "#000000" }, { pos: 1, color: "#111111" })
        return { vertical: vertical, stops: stops }
    }
    function splitTopLevel(s) {   // split on commas not inside parens (rgba())
        const out = []; let depth = 0, cur = ""
        for (const ch of s) {
            if (ch === "(") depth++
            else if (ch === ")") depth--
            if (ch === "," && depth === 0) { out.push(cur); cur = "" }
            else cur += ch
        }
        if (cur.trim()) out.push(cur)
        return out
    }

    // ---- procedural animated backgrounds ----
    // Smooth fields are fragment shaders (src/qml/shaders/*.frag.in, committed
    // .qsb) rather than a full-window raster per tick; they share the C++
    // renderers' mulberry32 seed and 33ms clock so mini and full stay
    // pixel-identical.
    readonly property var animatedTypes: ["orbs","waves","aurora","mesh","bokeh","particles","starfield",
                                          "vis-bars","vis-radial","vis-oscilloscope"]
    readonly property bool animated: animatedTypes.indexOf(type) >= 0
    readonly property var shaderTypes: ["orbs","aurora","mesh","bokeh"]
    readonly property bool shaderType: shaderTypes.indexOf(type) >= 0

    property real tNow: 0
    Timer {
        interval: 33; repeat: true
        running: root.shaderType && root.visible && !root.hold
        onRunningChanged: if (running) root.tNow = BgClock.now()
        onTriggered: root.tNow = BgClock.now()
    }
    function bgColors(def) {
        return String(root.opts.colors || def).split(",")
            .map((s) => s.trim()).filter((s) => s.length > 0)
    }
    function colAt(arr, i) { return i < arr.length ? arr[i] : "transparent" }
    function optN(name, def) {
        const v = Number(root.opts[name])
        return isNaN(v) ? def : v
    }

    Loader {
        x: root.renderX; y: root.renderY; width: root.renderW; height: root.renderH
        transform: [
            Scale { origin.x: root.renderW/2; origin.y: root.renderH/2
                    xScale: root.cfgScale; yScale: root.cfgScale },
            Translate { x: root.cfgPosX * root.renderW; y: root.cfgPosY * root.renderH }
        ]
        opacity: root.bgOpacity
        active: root.shaderType
        sourceComponent: root.type === "orbs" ? orbsComp
                       : root.type === "aurora" ? auroraComp
                       : root.type === "mesh" ? meshComp : bokehComp
    }
    component BgShader: ShaderEffect {
        anchors.fill: parent
        property real time: root.tNow
        property real resW: root.renderW
        property real resH: root.renderH
        // counts scale with render area against 1920x1080; scaleMode = classic | count | size | off
        readonly property string scaleMode: String(root.opts.scaleMode || "classic")
        readonly property real areaRatio: (root.renderW * root.renderH) / 2073600
        function effCount(base) {
            return (scaleMode === "size" || scaleMode === "off") ? base
                 : Math.max(1, Math.round(base * Math.sqrt(areaRatio)))
        }
        property var pal: []
        property int nColors: pal.length
        property color c0: root.colAt(pal, 0)
        property color c1: root.colAt(pal, 1)
        property color c2: root.colAt(pal, 2)
        property color c3: root.colAt(pal, 3)
        property color c4: root.colAt(pal, 4)
        property color c5: root.colAt(pal, 5)
        property color c6: root.colAt(pal, 6)
        property color c7: root.colAt(pal, 7)
    }
    Component {
        id: orbsComp
        BgShader {
            fragmentShader: Qt.resolvedUrl("../shaders/orbs.frag.qsb")
            pal: root.bgColors("#cc3333,#4a9eff,#4daa5c,#e06088")
            property real speed: root.optN("speed", 1) * 0.2
            property real count: root.optN("count", 8)
            property real minSize: root.optN("minSize", 60)
            property real maxSize: root.optN("maxSize", 200)
            property real ss: (scaleMode === "count" || scaleMode === "off")
                              ? 1 : Math.pow(areaRatio, 0.25)
            property real n: effCount(count)
        }
    }
    Component {
        id: auroraComp
        BgShader {
            fragmentShader: Qt.resolvedUrl("../shaders/aurora.frag.qsb")
            pal: root.bgColors("#00ff88,#4a9eff,#cc3333,#e06088")
            property real speed: root.optN("speed", 1) * 0.2
            property real bands: root.optN("bands", 4)
            property real intensity: root.optN("intensity", 0.6)
        }
    }
    Component {
        id: meshComp
        BgShader {
            fragmentShader: Qt.resolvedUrl("../shaders/mesh.frag.qsb")
            pal: root.bgColors("#cc3333,#4a9eff,#4daa5c,#e06088")
            property real speed: root.optN("speed", 1) * 0.2
            property real blobSize: root.optN("blobSize", 0.6)
        }
    }
    Component {
        id: bokehComp
        BgShader {
            fragmentShader: Qt.resolvedUrl("../shaders/bokeh.frag.qsb")
            pal: root.bgColors("#cc3333,#4a9eff,#e06088,#ffffff")
            property real speed: root.optN("speed", 1) * 0.2
            property real count: root.optN("count", 15)
            property real sizeRange: root.optN("sizeRange", 60)
            property real baseSize: root.optN("size", 20)
            property real ss: (scaleMode === "count" || scaleMode === "off")
                              ? 1 : Math.pow(areaRatio, 0.25)
            property real n: effCount(count)
        }
    }
    // audio-reactive vis types drive the FFT source; keep it running only
    // while one of them is the active background (and this layer is shown)
    readonly property bool isVis: type === "vis-bars" || type === "vis-radial" || type === "vis-oscilloscope"
    // One owner key for both instances (full window and mini bar): both read
    // Theme.background, so they always request the same thing. An instance with
    // a different `config` (e.g. a settings preview) needs its own key.
    // SpectrumSource arbitrates against plugin requests.
    function syncSpectrum() {
        if (typeof Spectrum !== "undefined") Spectrum.request("background", isVis)
    }
    onIsVisChanged: syncSpectrum()
    Component.onCompleted: syncSpectrum()
    // particles: scene-graph geometry (ParticlesItem); painting them would
    // rasterize hundreds of AA lines into a full-window texture per tick
    ParticlesItem {
        x: root.renderX; y: root.renderY; width: root.renderW; height: root.renderH
        transform: [
            Scale { origin.x: root.renderW/2; origin.y: root.renderH/2
                    xScale: root.cfgScale; yScale: root.cfgScale },
            Translate { x: root.cfgPosX * root.renderW; y: root.cfgPosY * root.renderH }
        ]
        visible: root.type === "particles"
        opacity: root.bgOpacity
        config: root.type === "particles" ? root.config : ({ type: "none" })
        hold: root.hold
    }

    BackgroundItem {
        id: canvas
        x: root.renderX; y: root.renderY; width: root.renderW; height: root.renderH
        transform: [
            Scale { origin.x: canvas.width/2; origin.y: canvas.height/2
                    xScale: root.cfgScale; yScale: root.cfgScale },
            Translate { x: root.cfgPosX * canvas.width; y: root.cfgPosY * canvas.height }
        ]
        // A QML Canvas could paint without its texture being shown until a node
        // rebuild; this QQuickPaintedItem (src/vis/BackgroundItem.cpp) updates inside
        // the scene-graph frame, and both instances share a fixed seed and 33ms clock,
        // so they render identical frames.
        visible: !root.shaderType && root.type !== "particles"
        opacity: root.bgOpacity
        // shader/geometry-rendered types hand the painted item an inert config
        config: root.shaderType || root.type === "particles" ? ({ type: "none" }) : root.config
        hold: root.hold
    }
}
