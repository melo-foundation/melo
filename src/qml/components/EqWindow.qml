import QtQuick
import ".."

// Equalizer window: EQ toggle, preset select and Reset, then a Catmull-Rom curve
// through 10 draggable band nodes (drag sets dB, double-click resets a band).
// State is ui.eqConfig {bands[10], enabled, preset}; user edits apply live and
// persist. Plugins share the engine through MeloUi.eq, so this also refreshes
// from Player.eqBands() on Player.eqChanged, without persisting. The preamp is
// plugin-only; applyEqConfig leaves it alone.
Window {
    id: win
    // A rounded corner is at most half its rectangle's height, so the title bar
    // draws less than the window radius when it is short; the ground and the
    // border above it follow what it draws, or the bar pokes past their curve
    readonly property real topCornerRadius: framed && !Theme.borderTitle ? Theme.windowRadius
        : Math.min(Theme.windowRadius, Theme.titleBarH / 2)
    // What the window's shape eats into each edge (WindowShapeItem.intrusion): the
    // title bar's ends and the body under it, so a cut deeper than the frame does not
    // take the words and controls drawn there.
    property real cutTitleL: 0
    property real cutTitleR: 0
    property real cutBodyL: 0
    property real cutBodyR: 0
    // a surface fills a shaped window and the shape cuts it; what sits on it
    // starts inside the deeper of the frame and the cut
    readonly property bool shaped: shapeLoader.item && shapeLoader.item.active && shapeLoader.item.hasShape
    function readCuts() {
        const sh = shapeLoader.item
        const titleH = Theme.titleBarH
        cutTitleL = shaped ? Math.max(frL, sh.intrusion("left", 0, titleH)) : frL
        cutTitleR = shaped ? Math.max(frR, sh.intrusion("right", 0, titleH)) : frR
        cutBodyL = shaped ? Math.max(frL, sh.intrusion("left", titleH, height)) : frL
        cutBodyR = shaped ? Math.max(frR, sh.intrusion("right", titleH, height)) : frR
    }
    onShapedChanged: readCuts()
    readonly property bool frameOff: (win.visibility === Window.Maximized || win.visibility === Window.FullScreen)
                                     && !Theme.borderMaximized
    readonly property real frL: frameOff ? 0 : Theme.borderLeft
    readonly property real frT: frameOff ? 0 : Theme.borderTop
    readonly property real frR: frameOff ? 0 : Theme.borderRight
    readonly property real frB: frameOff ? 0 : Theme.borderBottom
    readonly property bool framed: frL > 0 || frT > 0 || frR > 0 || frB > 0
    readonly property real titleGap: Theme.borderTitle ? frT : 0
    readonly property real titleCap: framed && !Theme.borderTitle ? Math.max(0, Theme.windowRadius - Math.max(frL, frT)) : Theme.windowRadius

    width: 460
    height: 320
    minimumWidth: 380
    minimumHeight: 260
    visible: false
    color: "transparent"
    title: "melo equalizer"
    flags: Qt.Window | Qt.FramelessWindowHint

    property var bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    property bool eqEnabled: true
    property string preset: "flat"
    property int hoverIdx: -1
    property int dragIdx: -1

    readonly property var freqValues: [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    readonly property var freqLabels: ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    readonly property var presets: ({
        "flat":         [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "bass-boost":   [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
        "treble-boost": [0, 0, 0, 0, 0, 0, 2, 4, 5, 6],
        "bass-treble":  [5, 4, 2, 0, -2, -2, 0, 2, 4, 5],
        "vocal":        [-2, -1, 0, 2, 4, 4, 2, 0, -1, -2],
        "electronic":   [5, 4, 1, 0, -2, 0, 1, 3, 4, 5],
        "rock":         [4, 3, 1, 0, -1, -1, 0, 2, 3, 4],
        "acoustic":     [3, 2, 1, 0, 0, 1, 2, 2, 3, 2],
    })
    readonly property var presetLabels: ({
        "flat": "Flat", "bass-boost": "Bass Boost", "treble-boost": "Treble Boost",
        "bass-treble": "Bass + Treble", "vocal": "Vocal", "electronic": "Electronic",
        "rock": "Rock", "acoustic": "Acoustic", "custom": "Custom",
    })

    function open() {
        const eq = Settings.uiGet("eqConfig", null)
        if (eq && eq.bands && eq.bands.length === 10) {
            bands = eq.bands.slice()
            eqEnabled = eq.enabled === true
            preset = eq.preset || "custom"
        }
        // ...then let the engine correct it: a plugin may have moved the curve
        // while this window was closed, and the engine is the live truth.
        refreshFromEngine()
        applyGlass()
        visible = true
        requestActivate()
        canvas.repaint()
    }
    function applyGlass() {
        const on = Theme.glassBlur !== "off" && Theme.translucent("window")
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(win, on)
    }

    // persist + apply to the engine
    function commit() {
        Settings.uiSet("eqConfig", { bands: bands, enabled: eqEnabled, preset: preset })
        Player.applyEqConfig({ bands: bands, enabled: eqEnabled })
        canvas.repaint()
    }
    function setBand(i, db) {
        const b = bands.slice()
        b[i] = Math.round(db * 2) / 2   // 0.5 dB steps
        bands = b
        preset = "custom"
        if (eqEnabled) Player.setEqBand(i, b[i])   // live while dragging
        canvas.repaint()
    }

    // Plugins also write the engine through MeloUi.eq, so pull the curve back whenever
    // the engine's copy moves. Never persists: eqConfig is the user's preset and only
    // their own edits (commit) may rewrite it.
    function refreshFromEngine() {
        // With the EQ off the engine holds flat while this window greys out the user's
        // curve; pulling would erase it. A plugin's changes while off are heard but not
        // shown.
        if (!eqEnabled || dragIdx >= 0) return   // mid-drag: the pointer wins
        const live = Player.eqBands()
        if (!live || live.length !== 10) return
        // Compare against what the engine CAN hold. A hand-edited or
        // legacy-imported eqConfig may carry a band outside -24..+12, which
        // reads back clamped; a raw diff would call that "someone else moved
        // it" and silently rename the user's saved preset to Custom.
        let differs = false
        for (let i = 0; i < 10; i++)
            if (live[i] !== Math.max(-24, Math.min(12, bands[i]))) { differs = true; break }
        if (!differs) return   // our own commit echoing back; keep the preset name
        bands = live.slice()
        preset = "custom"      // someone else moved it: it is no longer that preset
        canvas.repaint()
    }

    Connections {
        target: Player
        function onEqChanged() { win.refreshFromEngine() }
    }

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
        // the top corners as the title bar draws them: no more than half its height
        topLeftRadius: win.topCornerRadius; topRightRadius: win.topCornerRadius
        bottomLeftRadius: Theme.windowRadiusBottom; bottomRightRadius: Theme.windowRadiusBottom
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.y + titleBar.height + win.titleGap
        anchors.leftMargin: win.shaped ? 0 : win.frL
        anchors.rightMargin: win.shaped ? 0 : win.frR
        anchors.bottomMargin: win.shaped ? 0 : win.frB
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frL, win.frB))
        bottomRightRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frR, win.frB))
        visible: Theme.hasPage
    }
    Loader {   // the window's shape (WindowMask)
        id: shapeLoader
        parent: win.contentItem
        anchors.fill: parent
        z: 10000000
        active: typeof WindowCtl !== "undefined"
        source: "WindowMask.qml"
        onLoaded: {
            item.shapeApplied.connect(win.readCuts)
            item.spec = Qt.binding(() => Theme.panelShapeFor(win.topCornerRadius, Theme.windowRadiusBottom))
            // a maximised window is the screen's shape
            item.active = Qt.binding(() => item.spec !== null && win.visibility !== Window.Maximized
                                           && win.visibility !== Window.FullScreen)
        }
    }
    WindowBorder {   // the window frame and border; with the title in it, round the title too
        anchors.fill: parent
        borderLeft: win.frL; borderTop: win.frT; borderRight: win.frR; borderBottom: win.frB
        titleHeight: Theme.borderTitle && !win.frameOff ? titleBar.height : 0
        shape: shapeLoader.item && shapeLoader.item.active ? shapeLoader.item : null
        titleRim: win.frameOff ? 0 : Theme.borderTitleRim
        titleFade: Theme.borderTitleFade
        radiusTL: win.topCornerRadius
        radiusTR: win.topCornerRadius
        radiusBL: Theme.windowRadiusBottom; radiusBR: Theme.windowRadiusBottom
        visible: win.framed || (!win.frameOff && Theme.frameDepth > 0)
        z: 1000
    }

    Surface {   // title bar
        id: titleBar
        x: Theme.borderTitle ? 0 : win.frL
        y: Theme.borderTitle ? 0 : win.frT
        width: parent.width - (Theme.borderTitle ? 0 : win.frL + win.frR)
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Math.min(win.titleCap, height / 2)
        topRightRadius: Math.min(win.titleCap, height / 2)
        MouseArea { anchors.fill: parent; onPressed: win.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left
            anchors.leftMargin: Theme.inset("title", "left") + win.cutTitleL - (Theme.borderTitle ? 0 : win.frL)
            text: "Equalizer"
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(Theme.titleFontSize); family: Theme.fontFamily; weight: Theme.titleWeight }
        }
        Item {
            anchors.right: parent.right
            anchors.rightMargin: Theme.inset("title", "right") + win.cutTitleR - (Theme.borderTitle ? 0 : win.frR)
            // on whole pixels, as the main window's buttons are
            y: Math.round((parent.height - height + Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2)
            width: Theme.titleButtons === "button" ? Theme.titleBtn : Theme.ctl(26)
            height: Theme.titleButtons === "button" && Number(Theme.ts.titleButtonSize) > 0 ? Theme.titleBtn : Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(13)
                ink: closeMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: closeMa.containsMouse; pressed: closeMa.pressed
                frameWidth: Theme.titleBtn; frameHeight: Theme.titleBtnH }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: win.visible = false }
        }
    }

    // preset row: [x] EQ | preset select | Reset
    Item {
        id: presetRow
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // the tool-window inset, as the picker's and the shelf's body
        anchors.leftMargin: Theme.inset("tool", "left") + win.cutBodyL
        anchors.rightMargin: Theme.inset("tool", "right") + win.cutBodyR
        anchors.topMargin: Theme.inset("tool", "top") + win.titleGap
        height: Theme.btnH

        Row {
            spacing: Theme.gap(10)
            anchors.verticalCenter: parent.verticalCenter
            Surface {   // EQ enable checkbox
                width: Theme.ctl(16); height: Theme.ctl(16); radius: Theme.radiusSm
                anchors.verticalCenter: parent.verticalCenter
                role: win.eqEnabled ? "accent" : "button"
                borderWidth: 1
                borderRole: win.eqEnabled ? "accent" : "border"
                InkText { anchors.centerIn: parent; visible: win.eqEnabled
                       text: "✓"; ink: "textOnAccent"; font.pixelSize: Theme.fs(11) }
                MouseArea { anchors.fill: parent
                            onClicked: { win.eqEnabled = !win.eqEnabled; win.commit() } }
            }
            InkText { anchors.verticalCenter: parent.verticalCenter
                   text: "EQ"; ink: "text"
                   font { pixelSize: Theme.fs(13); family: Theme.fontFamily } }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.gap(6)
            SelectHead {   // preset select
                id: presetMa
                label: win.presetLabels[win.preset] || win.preset
                menu: eqMenu
                onClicked: {
                    const p = presetMa.mapToItem(null, 0, presetMa.height + 2)
                    const opts = Object.keys(win.presets).map((k) =>
                        ({ label: win.presetLabels[k], act: () => {
                            win.preset = k
                            win.bands = win.presets[k].slice()
                            win.commit()
                        } }))
                    eqMenu.openAt(win, p.x, p.y, opts, presetMa)
                }
            }
            PushButton {   // reset
                label: "Reset"
                onClicked: { win.preset = "flat"
                             win.bands = [0,0,0,0,0,0,0,0,0,0]
                             win.commit() }
            }
        }
    }

    // ---------- the curve canvas ----------
    // Grid and labels are flat. The curve, its fill and the nodes use the graph key
    // like a glyph: painted white on a layer-only canvas whose coverage the key's fill
    // reads; a plain colour paints the canvas directly. The tooltip is a Surface on
    // the same key.
    Item {
        id: canvas
        anchors.top: presetRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.inset("tool", "left") + win.cutBodyL
        anchors.rightMargin: Theme.inset("tool", "right") + win.cutBodyR
        anchors.bottomMargin: Theme.inset("tool", "bottom") + win.frB
        anchors.topMargin: Theme.gap(8)

        readonly property int padL: 32
        readonly property int padR: 10
        readonly property int padT: 10
        readonly property int padB: 20
        readonly property real minDb: -12
        readonly property real maxDb: 12

        function freqToX(f) {
            const lmin = Math.log10(20), lmax = Math.log10(20000)
            return padL + ((Math.log10(f) - lmin) / (lmax - lmin)) * (width - padL - padR)
        }
        function dbToY(db) {
            return padT + ((maxDb - db) / (maxDb - minDb)) * (height - padT - padB)
        }
        function yToDb(y) {
            const r = (y - padT) / (height - padT - padB)
            return Math.max(minDb, Math.min(maxDb, maxDb - r * (maxDb - minDb)))
        }
        function catmullRom(pts, seg) {
            if (pts.length < 2) return pts
            const ext = [[pts[0][0] * 2 - pts[1][0], pts[0][1]], ...pts,
                         [pts[pts.length-1][0] * 2 - pts[pts.length-2][0], pts[pts.length-1][1]]]
            const out = []
            for (let i = 1; i < ext.length - 2; i++) {
                const p0 = ext[i-1], p1 = ext[i], p2 = ext[i+1], p3 = ext[i+2]
                for (let t = 0; t <= 1; t += 1 / seg) {
                    const t2 = t*t, t3 = t2*t
                    out.push([
                        0.5 * ((2*p1[0]) + (-p0[0]+p2[0])*t + (2*p0[0]-5*p1[0]+4*p2[0]-p3[0])*t2 + (-p0[0]+3*p1[0]-3*p2[0]+p3[0])*t3),
                        0.5 * ((2*p1[1]) + (-p0[1]+p2[1])*t + (2*p0[1]-5*p1[1]+4*p2[1]-p3[1])*t2 + (-p0[1]+3*p1[1]-3*p2[1]+p3[1])*t3)])
                }
            }
            return out
        }

        readonly property var r: Theme.role("graph")
        readonly property bool twin: Theme.isStyled(r.source) || r.source === "adaptive"
        function repaint() {
            grid.requestPaint(); flat.requestPaint()
            if (cover.item) cover.item.requestPaint()
        }

        // everything the accent draws, in one colour: the mask is this in white
        function drawCurve(ctx, col, w, h) {
            ctx.clearRect(0, 0, w, h)
            const zeroY = dbToY(0)
            const cps = win.freqValues.map((f, i) => [freqToX(f), dbToY(win.bands[i] || 0)])
            const all = [[padL, dbToY(win.bands[0] || 0)], ...cps,
                         [w - padR, dbToY(win.bands[9] || 0)]]
            const curve = catmullRom(all, 20)
            ctx.fillStyle = col; ctx.strokeStyle = col
            // fill under the curve
            ctx.globalAlpha = 0.12
            ctx.beginPath()
            ctx.moveTo(curve[0][0], zeroY)
            for (const p of curve) ctx.lineTo(p[0], p[1])
            ctx.lineTo(curve[curve.length-1][0], zeroY)
            ctx.closePath(); ctx.fill()
            // the curve
            ctx.globalAlpha = 1
            ctx.beginPath()
            ctx.moveTo(curve[0][0], curve[0][1])
            for (let i = 1; i < curve.length; i++) ctx.lineTo(curve[i][0], curve[i][1])
            ctx.lineWidth = 2; ctx.stroke()
            // the nodes
            for (let i = 0; i < cps.length; i++) {
                const hot = win.hoverIdx === i || win.dragIdx === i
                const rad = hot ? 7 : 5
                if (hot) {
                    ctx.globalAlpha = 0.2
                    ctx.beginPath(); ctx.arc(cps[i][0], cps[i][1], rad + 4, 0, Math.PI * 2); ctx.fill()
                }
                ctx.globalAlpha = 1
                ctx.beginPath(); ctx.arc(cps[i][0], cps[i][1], rad, 0, Math.PI * 2); ctx.fill()
            }
        }

        Canvas {
            id: grid
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = String(Theme.border)
                // the zero line is the same hairline, twice as wide
                for (const db of [-12, -6, 0, 6, 12]) {
                    const y = canvas.dbToY(db)
                    ctx.lineWidth = db === 0 ? 2 : 1
                    ctx.beginPath(); ctx.moveTo(canvas.padL, y); ctx.lineTo(width - canvas.padR, y); ctx.stroke()
                }
                ctx.lineWidth = 1
                for (const f of [50, 100, 200, 500, 1000, 2000, 5000, 10000]) {
                    const x = canvas.freqToX(f)
                    if (x < canvas.padL || x > width - canvas.padR) continue
                    ctx.beginPath(); ctx.moveTo(x, canvas.padT); ctx.lineTo(x, height - canvas.padB); ctx.stroke()
                }
            }
        }
        Repeater {
            model: [-12, -6, 0, 6, 12]
            InkText {
                required property int modelData
                x: canvas.padL - 5 - width; y: canvas.dbToY(modelData) - height / 2
                text: modelData === 0 ? "0" : (modelData > 0 ? "+" + modelData : String(modelData))
                ink: "text"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }
        Repeater {
            model: 10
            InkText {
                required property int index
                x: canvas.freqToX(win.freqValues[index]) - width / 2
                y: canvas.height - canvas.padB + 5
                text: win.freqLabels[index]
                ink: "text"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }

        Item {
            anchors.fill: parent
            opacity: win.eqEnabled ? 1 : 0.25
            Canvas {
                id: flat
                anchors.fill: parent
                visible: !canvas.twin
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: canvas.drawCurve(getContext("2d"), String(Theme.graph), width, height)
            }
            // the twin: built whole so the layer exists before the fill binds
            Loader {
                id: cover
                anchors.fill: parent
                active: canvas.twin
                sourceComponent: Item {
                    function requestPaint() { white.requestPaint() }
                    Item {
                        width: 0; height: 0; clip: true
                        Item {
                            id: coverage
                            width: canvas.width; height: canvas.height
                            layer.enabled: true; layer.smooth: true
                            Canvas {
                                id: white
                                anchors.fill: parent
                                onWidthChanged: requestPaint()
                                onHeightChanged: requestPaint()
                                onPaint: canvas.drawCurve(getContext("2d"), "#ffffff", width, height)
                            }
                        }
                    }
                    StyledFill {
                        anchors.fill: parent
                        visible: Theme.layered(canvas.r)
                        mask: coverage
                        kind: canvas.r.source
                        params: canvas.r.params
                        colourA: canvas.r.colour
                        layers: canvas.r.layers
                        opacity: canvas.r.opacity
                    }
                    HueLum {
                        anchors.fill: parent
                        visible: canvas.r.source === "adaptive"
                        backdrop: visible ? Theme.backdrop : null
                        mask: coverage
                        hue: canvas.r.amounts.x
                        lum: canvas.r.amounts.y
                        sat: canvas.r.amounts.z
                        opacity: canvas.r.amounts.w * canvas.r.opacity
                    }
                }
            }
        }

        Surface {   // the tooltip over the hot node
            readonly property int i: win.dragIdx >= 0 ? win.dragIdx : win.hoverIdx
            readonly property real gain: i >= 0 ? (win.bands[i] || 0) : 0
            visible: i >= 0 && win.eqEnabled
            width: tipText.implicitWidth + 12; height: 18
            radius: 4
            role: "graph"
            opacity: 0.85
            x: i < 0 ? 0 : Math.max(canvas.padL, Math.min(canvas.freqToX(win.freqValues[i]) - width / 2,
                                                          canvas.width - canvas.padR - width))
            y: i < 0 ? 0 : canvas.dbToY(gain) - 7 - 22
            InkText {
                id: tipText
                anchors.centerIn: parent
                ink: "textOnAccent"
                text: parent.i < 0 ? "" : win.freqLabels[parent.i] + "Hz  " + (parent.gain > 0 ? "+" : "") + parent.gain + "dB"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: win.hoverIdx >= 0 || win.dragIdx >= 0
                         ? Qt.PointingHandCursor : Qt.ArrowCursor
            function hitTest(mx, my) {
                for (let i = 0; i < 10; i++) {
                    const dx = mx - canvas.freqToX(win.freqValues[i])
                    const dy = my - canvas.dbToY(win.bands[i] || 0)
                    if (dx * dx + dy * dy <= 144) return i   // 12px hit radius
                }
                return -1
            }
            onPressed: (m) => {
                if (!win.eqEnabled) return
                const i = hitTest(m.x, m.y)
                if (i >= 0) { win.dragIdx = i; win.setBand(i, canvas.yToDb(m.y)) }
            }
            onPositionChanged: (m) => {
                if (win.dragIdx >= 0) { win.setBand(win.dragIdx, canvas.yToDb(m.y)); return }
                const i = hitTest(m.x, m.y)
                if (i !== win.hoverIdx) { win.hoverIdx = i; canvas.repaint() }
            }
            onReleased: {
                if (win.dragIdx >= 0) { win.dragIdx = -1; win.commit() }
            }
            onDoubleClicked: (m) => {
                if (!win.eqEnabled) return
                const i = hitTest(m.x, m.y)
                if (i >= 0) { win.setBand(i, 0); win.commit() }
            }
            onExited: { if (win.hoverIdx !== -1) { win.hoverIdx = -1; canvas.repaint() } }
        }
    }

    DropMenu { id: eqMenu }

    Connections {
        target: ThemeBackend
        function onThemeChanged() { canvas.repaint(); if (win.visible) win.applyGlass() }
    }

    Shortcut { sequence: "Escape"; onActivated: win.visible = false }
}
