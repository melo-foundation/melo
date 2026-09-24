import QtQuick
import QtQuick.Effects
import "barstyles"
import ".."
import "barswap.js" as Swap

// Player bar, default layout (docs/bar-layout.md):
// Row 1 (full width): thumb 48x28 r2 + title 13px/600 + artist 11px.
// Row 2: [prev|play|next 22px bare icons] [time | 6px bar | time] [EQ] [queue].
// Wheel anywhere = volume ±0.05 with 1s toast. Click bar = seek.
Rectangle {
    id: bar
    // Each layout states its barHeight; root.barH drives the mini window and the
    // offsets around this bar, which never reads it.
    // settleLayout is the key this bar will settle on: through a mini toggle the
    // revealed bar first takes the outgoing bar's layout so it has a change to play.
    // settledHeight is the unanimated end height; the page lays out against it so it
    // is not re-laid while the bar moves (the bar follows the rows' clock, barswap.js).
    property string settleLayout: ""
    readonly property real settledHeight: {
        const dep = pool
        const k = settleLayout.length ? settleLayout : layout
        const it = pool[k] || shownItem
        return it ? it.barHeight : Theme.bar(77)
    }
    onSettledHeightChanged: if (typeof MELO_BAR_DEBUG !== "undefined" && MELO_BAR_DEBUG)
        console.warn("[bar] " + (mini ? "mini" : "main") + " settled=" + Math.round(settledHeight)
                     + " h=" + Math.round(height) + " layout=" + layout
                     + " shown=" + (shownItem ? shownItem.key : "none"))
    height: Swap.barHeight(swapping, fromH, morphIn, settledHeight)
    // on the swap's clock, so the height lands with the layouts, not before
    // or after them. Ease, a spring with an overshoot, or a snap, as the
    // theme says.
    Behavior on height {
        enabled: Theme.barResize !== "snap"
        NumberAnimation { duration: Theme.barSwapMs
                          easing.type: Theme.barResize === "spring" ? Easing.OutBack : Theme.motionEase
                          easing.overshoot: 1.4 }
    }
    // The ground is a Surface child (a root cannot change type without changing every
    // caller), so this stays transparent and the bar can blend or adapt. A backing
    // change crossfades the ground over the swap; a layout swap on the same backing
    // leaves it alone.
    color: "transparent"
    property string shownBacking: backing
    property string prevBacking: backing
    property real backT: 1
    // The ground waits for the rows. A swap holds until the incoming renderer
    // has been drawn (`pending`), so its first animated frame is a drawn one;
    // a ground that started at once would reshape the card around the OLD
    // rows for as long as the incoming build took.
    onBackingChanged: {
        prevBacking = shownBacking; shownBacking = backing
        if (typeof MELO_BAR_DEBUG !== "undefined" && MELO_BAR_DEBUG)
            console.warn("[bar] backing " + prevBacking + " -> " + backing
                         + " swap=" + swap + " quiet=" + quiet + " swapping=" + swapping)
        // A backing that changes WITH the layout has no animation of its own —
        // groundT follows the incoming rows instead. This only matters when the
        // backing changes by itself.
        if (swap === "none" || quiet || swapping) { backAnim.stop(); backT = 1; return }
        backAnim.restart()
    }
    // A swap is in flight from the moment arrive() sets the clock to 0 —
    // including the wait for the incoming renderer to be drawn, which happens
    // at layoutT === 0.
    readonly property bool swapping: layoutT < 1
    // Where the ground is: on the rows' clock while they change (see
    // barswap.js).
    readonly property real groundT: Swap.groundProgress(swapping, morphIn, backT)
    // MELO_BAR_DEBUG=1: the two clocks side by side. They must move together —
    // a ground that reaches 1 while the rows are still at 0 is the card
    // changing shape around the layout it is replacing.
    onGroundTChanged: if (typeof MELO_BAR_DEBUG !== "undefined" && MELO_BAR_DEBUG)
        console.warn("[bar] ground=" + groundT.toFixed(2) + " rowsIn=" + morphIn.toFixed(2)
                     + " rowsOut=" + morphOut.toFixed(2) + " h=" + Math.round(height)
                     + " (" + Math.round(fromH) + "->" + Math.round(toH) + ")")
    NumberAnimation { id: backAnim; target: bar; property: "backT"; from: 0; to: 1
                      duration: Theme.barSwapMs; easing.type: Theme.motionEase }
    // the corners it has at the window's edge: the window's, or what a frame
    // round it leaves (Main sets it for the full bar)
    property real edgeRadius: Theme.windowRadius
    // What the window's shape cuts from the bar, per end: the rows start inside it,
    // so a cut corner takes no control with it. Top and foot cuts are the theme's to
    // keep shallow; the rows are a stack of fixed height.
    property real cutLeft: 0
    property real cutRight: 0
    // the floating card's inset from the bar's edges, the same on every side; the
    // theme's offset moves it off centre. The layouts read it.
    readonly property real inset: Theme.gap(Theme.floatInset)
    readonly property real cardTop: Math.max(0, inset + Theme.gap(Theme.floatOffset))
    readonly property real cardBottom: Math.max(0, inset - Theme.gap(Theme.floatOffset))
    component Ground: Surface {
        property string kind: "surface"
        readonly property bool card: kind === "floating"
        anchors.fill: parent
        anchors.leftMargin: card ? bar.inset : 0
        anchors.rightMargin: card ? bar.inset : 0
        anchors.bottomMargin: card ? bar.cardBottom : 0
        anchors.topMargin: card ? bar.cardTop : 0
        z: -1
        role: kind === "none" ? "" : "player"
        radius: card ? Theme.radiusLg : 0
        topLeftRadius: card ? Theme.radiusLg : (bar.mini ? bar.edgeRadius : 0)
        topRightRadius: card ? Theme.radiusLg : (bar.mini ? bar.edgeRadius : 0)
        bottomLeftRadius: card ? Theme.radiusLg : bar.edgeRadius
        bottomRightRadius: card ? Theme.radiusLg : bar.edgeRadius
    }
    Ground { kind: bar.prevBacking; opacity: 1 - bar.groundT; visible: opacity > 0.01 }
    Ground { kind: bar.shownBacking; opacity: bar.groundT; visible: opacity > 0.01 }
    // window corner rounding: the bar IS the window's bottom edge (and the
    // whole window in mini mode). The mini popup is a SEPARATE rounded card
    // (rounded top+bottom, small gap above), so the bar always keeps its own
    // rounded top in mini — no seam to worry about.
    topLeftRadius: mini ? edgeRadius : 0
    topRightRadius: mini ? edgeRadius : 0
    bottomLeftRadius: edgeRadius
    bottomRightRadius: edgeRadius

    // full mode: separates the bar from the content above. Hidden in mini —
    // there's nothing above, and a straight line across the rounded top reads
    // wrong (and the window border/outline handles the edge there).
    Surface { anchors.top: parent.top; width: parent.width; height: 1
                role: "border"; visible: !bar.mini && bar.backing === "surface" }

    signal queueToggle()
    signal eqToggle()
    signal visToggle()
    signal dragStarted()
    property bool visActive: false
    property var barMenu: null   // shared Main.openBarMenu(sx, sy, host)
    // the mini bar is its own toplevel, so the main window's outside-click
    // layer never sees a press here — the bar closes the menu itself
    property var dismissMenus: null

    // Layout and backing, two choices a theme makes per place. rows: thumb and title
    // over transport, scrub and buttons. centre: transport in the middle, buttons a
    // gap away, scrub under it or on the window's edge, no title (the poster shows
    // it). Backing: player surface edge to edge, nothing, or a floating card.
    property string layout: "barMain:rows"   // "<slot>:<layoutId>", or a bare id
    property string backing: "surface"       // surface, none, floating
    readonly property string layoutId: layout.indexOf(":") >= 0 ? layout.slice(layout.indexOf(":") + 1) : layout
    readonly property bool bare: layoutId === "centre"
    // The settings editor shows this bar, scaled, and drags handles over
    // its buttons: nothing here reacts, every button shows, and the bar
    // says where each button and the transport are.
    property bool customising: false
    // the arranger's live preview: what the bar draws while a drag is in
    // flight, instead of the saved document
    property var docOverride: null
    function buttonRect(id, target) { return shownItem ? shownItem.buttonRect(id, target) : null }
    function transportCentreX(target) { return shownItem ? shownItem.transportCentreX(target) : 0 }
    function cellRect(r, c, target) { return shownItem ? shownItem.cellRect(r, c, target) : null }
    // for the arranger: the rows in force at this width, and whether they
    // are the document's narrow variant's
    readonly property var shownRows: shownItem ? shownItem.rowDocs : []
    readonly property bool narrowVariant: shownItem ? shownItem.variant !== null : false
    signal laidOut()
    Connections { target: bar.shownItem; function onLaidOut() { bar.laidOut() } }
    function rowRect(r, target) { const row = shownItem ? shownItem.rowAt(r) : null; return row ? row.mapToItem(target, 0, 0, row.width, row.height) : null }
    function rowCount() { return shownItem ? shownItem.rowDocs.length : 0 }

    property bool mini: false
    // LIVE mini-mode state (unlike `mini`, which says which instance this
    // is): flips at the toggle, driving the vis-button slide in BOTH bars
    property bool miniActive: false
    property bool eqActive: false
    // interactive resize in progress: the in-flight fill glide must snap at
    // the grab instant, because a tick landing up to 250ms before the press
    // leaves its 250ms animation running through the first resize frames;
    // the tick freeze stops only NEW ticks
    property bool holdAnims: false

    function fmtTime(s) {
        if (!isFinite(s) || s <= 0) return "0:00"
        const m = Math.floor(s / 60), sec = Math.floor(s % 60)
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    // wheel anywhere over the bar = ±0.05, 1s "73%" toast
    function wheelVolume(angleDeltaY) {
        const v = Math.max(0, Math.min(1,
            PlayerState.volume + (angleDeltaY > 0 ? 0.05 : -0.05)))
        Player.setVolume(v)
        volToast.show(Math.round(v * 100) + "%")
    }
    Surface {
        id: volToast
        function show(t) { toastText.text = t; opacity = 1; toastTimer.restart() }
        anchors.horizontalCenter: parent.horizontalCenter
        y: bar.mini ? 4 : -34   // above the bar; inside it when the bar IS the window
        width: toastText.implicitWidth + 20
        height: 24
        radius: Theme.radiusMd
        role: "toast"
        opacity: 0
        visible: opacity > 0
        z: 100
        Behavior on opacity { NumberAnimation { duration: Theme.motionFast; easing.type: Theme.motionEase } }
        InkText { id: toastText; anchors.centerIn: parent; ink: "text"
               font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightBase } }
        Timer { id: toastTimer; interval: 1000; onTriggered: volToast.opacity = 0 }
    }

    // Bar body = window drag surface; double-click is the catalog gesture
    // playerBar.doubleClick (default occupant: toggleCompact). Sits under the rows, so
    // only presses on empty bar space reach it. startSystemMove() on a bare press
    // grabs the pointer and eats the double-click's second click, so the move starts
    // only after >4px of movement.
    MouseArea {
        id: barBody
        anchors.fill: parent
        // right-click opens the bar menu: the playing track, then the bar
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point pressPos
        property bool moveStarted: false
        // wall clock to the millisecond, so a press and the move it leads to can
        // be put beside each other and beside anything else in the log
        function stamp() { return new Date().toISOString().substr(11, 12) }
        property double pressedAt: 0
        onPressed: (m) => {
            if (bar.dismissMenus) bar.dismissMenus()
            pressPos = Qt.point(m.x, m.y); moveStarted = false
            pressedAt = Date.now()
            if (typeof MELO_FOCUS_DEBUG !== "undefined" && MELO_FOCUS_DEBUG)
                console.warn(stamp() + " [drag] press on the bar: window.active="
                             + (Window.window ? Window.window.active : "?")
                             + " appActive=" + (typeof WindowCtl !== "undefined" ? WindowCtl.appActive : "?"))
        }
        onClicked: (m) => {
            if (m.button !== Qt.RightButton || !bar.barMenu) return
            const p = barBody.mapToItem(null, m.x, m.y)
            bar.barMenu(p.x, p.y, bar.Window.window)
        }
        onPositionChanged: (m) => {
            // only a left drag moves the window
            if (!(pressedButtons & Qt.LeftButton)) return
            if (!moveStarted && pressed &&
                (Math.abs(m.x - pressPos.x) > 4 || Math.abs(m.y - pressPos.y) > 4)) {
                moveStarted = true
                // A move is issued against a press, and the compositor decides
                // whether that press is one it will accept — a press that also
                // activated the window is often not. Whether it took is only
                // visible as a move that does not start, so say what was asked.
                if (typeof MELO_FOCUS_DEBUG !== "undefined" && MELO_FOCUS_DEBUG)
                    console.warn(stamp() + " [drag] startSystemMove "
                                 + Math.round(Date.now() - pressedAt) + "ms after the press, "
                                 + Math.round(Math.abs(m.x - pressPos.x) + Math.abs(m.y - pressPos.y))
                                 + "px, window.active=" + (Window.window ? Window.window.active : "?"))
                Window.window.startSystemMove()   // compositor takes the grab first
                bar.dragStarted()
            }
        }
        onDoubleClicked: {
            if (typeof CommandMap !== "undefined" && CommandMap)
                CommandMap.invokeGesture("playerBar.doubleClick")
        }
        // wheel passes through every child (none accept it) and lands here
        onWheel: (w) => bar.wheelVolume(w.angleDelta.y)
    }

    // One clock for the swap between any two layouts: which is arriving,
    // which is leaving, and how far along. The direction — whether what
    // arrives comes from below or above — follows the layouts' order, so a
    // swap and its reverse mirror each other.
    property string shownLayout: layout
    property string prevLayout: layout
    property real layoutT: 1
    NumberAnimation { id: layoutAnim; target: bar; property: "layoutT"; from: 0; to: 1
                      duration: Theme.barSwapMs; easing.type: Theme.motionEase }
    readonly property var layoutRank: ({ rows: 0, strip: 1, centre: 2 })
    function idOf(key) { const i = key.indexOf(":"); return i >= 0 ? key.slice(i + 1) : key }
    readonly property bool forward: (layoutRank[idOf(shownLayout)] ?? 0) >= (layoutRank[idOf(prevLayout)] ?? 0)
    readonly property real bareT: layoutT
    function alphaOf(side) { return side === "in" ? morphIn : side === "out" ? morphOut : 0 }
    function geoOf(side) { return side === "in" ? geoIn : side === "out" ? geoOut : geoIn }

    // Swap style, from Theme.swapGeometry's table. Rise: the arriving bar comes up
    // from below and the leaving one goes out the top, taking turns (overlapping would
    // show two bars in the same places). Drop and Slide: the same, downward and
    // sideways. Zoom: arriving settles from slightly large, leaving shrinks,
    // overlapping. Fade: a cross-fade. None: a cut.
    readonly property string swap: Theme.barTransition
    // BY HEIGHT: the bar that is about to be taller rises into place, the one
    // about to be shorter drops, and two of a height cross-fade. The heights
    // are read when the swap begins, not from the layouts' order.
    property real fromH: 0
    property real toH: 0
    readonly property string swapKind: {
        if (swap !== "height") return swap
        return Math.abs(toH - fromH) < 0.5 ? "fade" : (toH > fromH ? "rise" : "drop")
    }
    readonly property bool overlap: Theme.swapOverlaps(swapKind)
    readonly property real morphOut: overlap ? 1 - bareT : Math.max(0, 1 - bareT * 2)
    readonly property real morphIn: overlap ? bareT : Math.max(0, bareT * 2 - 1)
    readonly property var geoIn: Theme.swapGeometry(swapKind, true, forward, morphIn)
    readonly property var geoOut: Theme.swapGeometry(swapKind, false, forward, morphOut)
    // BLUR: each side goes soft as it goes, sharp as it arrives. The layer is
    // only alive while the swap is, so a still bar pays nothing for it.
    readonly property bool blurring: swapKind === "blur" && layoutT < 1
    function blurOf(side) { return side === "in" ? 1 - morphIn : 1 - morphOut }

    // Renderers: one per layout this bar has shown, built once and kept (rendererFor
    // sets the cap), so a swap rebuilds nothing, reloads no thumbnail and restarts no
    // title. They live in a clip so the outgoing one does not leave over the content
    // above the bar; the volume toast stays outside it.
    property var pool: ({})
    property Item shownItem: null
    property Item leavingItem: null
    // the renderer a swap is waiting on: it starts its clock once that one
    // has been drawn (Qt's frameSwapped after its rows laid out), so the
    // animation's first frame is a drawn frame and never a late one
    property Item pending: null
    property var warmKeys: []      // layouts to build at idle, for the swaps to come
    // quiet: the hidden bar lands its change without playing it. A mini toggle first
    // puts the bar about to be revealed on the outgoing layout and ground; animated,
    // the flip would reveal a bar already in motion.
    property bool quiet: false
    Component {
        id: layoutC
        BarLayout {
            property string key
            property string role: "off"
            // The shown renderer fills the bar, anchored to the bottom (the window's edge):
            // an "at: bottom" row lays its cell at the layout's foot, so the edge scrubber
            // sits flush only while renderer and bar are the same height. The outgoing one
            // keeps its height: the bar takes the shown renderer's height the moment a swap
            // is decided, and filling would restretch the old bar before the crossfade.
            property real frozenH: 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: role === "out" && frozenH > 0 ? frozenH : parent.height
            // `bar` is handed in at creation: inside this component the name is the
            // renderer's own property, not the bar's id.
            // As text first, so a re-read that yields the same document neither re-parses
            // nor re-binds this renderer's rows.
            readonly property string docText: role === "in" && bar && bar.docOverride ? JSON.stringify(bar.docOverride)
                                            : (bar ? Theme.slotJson(key, bar.mini) : "{}")
            doc: JSON.parse(docText)
            visible: role === "in" || (role === "out" && bar.layoutT < 1)
            layer.enabled: bar.blurring && role !== "off"
            layer.effect: MultiEffect { blurEnabled: true; blurMax: 32; blur: bar.blurOf(role) }
            opacity: role === "off" ? 0 : bar.alphaOf(role)
            transform: [
                Translate { x: bar.geoOf(role).x; y: bar.geoOf(role).y },
                Scale { origin.x: width / 2; origin.y: height / 2; xScale: bar.geoOf(role).s; yScale: bar.geoOf(role).s }
            ]
        }
    }
    function rendererFor(key) {
        if (pool[key]) return pool[key]
        // Room for the shown, the arriving and every warmed renderer; evict what nothing
        // asked for. Settings arrive after the first warm, so a flat cap of three would
        // evict a layout the warm had just built.
        const keys = Object.keys(pool)
        const cap = Math.max(3, warmKeys.length + 2)
        if (keys.length >= cap) {
            const spare = (k) => { const it = pool[k]; return it !== shownItem && it !== leavingItem && it !== pending }
            const drop = keys.find(k => spare(k) && warmKeys.indexOf(k) < 0) || keys.find(spare)
            if (drop) { pool[drop].destroy(); delete pool[drop] }
        }
        // Only the width is handed in: createObject applies values, not bindings, so a
        // height here would freeze the renderer at its creation height. A renderer born
        // at width 0 builds its narrow variant and tears it down a frame later, and a
        // cell destroyed mid-incubation stalls Qt's incubator queue.
        const it = layoutC.createObject(morphClip, { key: key, bar: bar, width: morphClip.width })
        pool[key] = it
        pool = pool   // re-assign so bindings on the pool see it
        return it
    }
    // Kinds of layout change: "same" when both keys name the same document (nothing
    // moves); "morph" when the rows match and only cells differ (the shown renderer
    // takes the new document and its cells glide on the move token); "swap"
    // otherwise, a crossfade between two renderers.
    function bareOf(text) { const d = JSON.parse(text); delete d.id; delete d.name; return JSON.stringify(d) }
    function shapeOf(text) {
        const d = JSON.parse(text)
        const strip = rows => (rows || []).map(r => { const o = Object.assign({}, r); delete o.cells; return o })
        d.rows = strip(d.rows)
        if (d.variants) d.variants = d.variants.map(v => Object.assign({}, v, { rows: strip(v.rows) }))
        delete d.id; delete d.name
        return JSON.stringify(d)
    }
    function changeKind(fromKey, toKey) {
        if (fromKey === toKey) return "same"
        const a = Theme.slotJson(fromKey, mini), b = Theme.slotJson(toKey, mini)
        if (bareOf(a) === bareOf(b)) return "same"
        return shapeOf(a) === shapeOf(b) ? "morph" : "swap"
    }
    // the shown renderer answers to a new key: its document binding follows
    property bool morphing: false
    // twice the move: a cell's glide starts a frame or two after the morph
    // does, and a Behavior switched off mid-glide leaves the cell where it was
    Timer { id: morphEnd; interval: Theme.motionMove * 2; onTriggered: bar.morphing = false }
    function rekey(it, key) {
        const was = it.key
        const other = pool[key]
        delete pool[was]; delete pool[key]
        it.key = key; pool[key] = it
        // a renderer already warm for the new key takes the old one's: both
        // stay built, nothing is rebuilt at idle
        if (other && other !== it) { other.key = was; pool[was] = other }
        pool = pool
        prevLayout = shownLayout; shownLayout = key
    }
    function arrive(key) {
        if (shownItem && shownItem.key === key) return
        if (shownItem && !docOverride) {
            const kind = changeKind(shownItem.key, key)
            if (kind === "same") { rekey(shownItem, key); layoutT = 1; return }
            if (kind === "morph") { morphing = true; morphEnd.restart(); rekey(shownItem, key); layoutT = 1; return }
        }
        const next = rendererFor(key)
        if (leavingItem && leavingItem !== next && leavingItem !== shownItem) leavingItem.role = "off"
        if (shownItem) {
            leavingItem = shownItem
            leavingItem.frozenH = leavingItem.height
            leavingItem.frozenEdge = leavingItem.edge
            leavingItem.frozenEdgeR = leavingItem.edgeRight
            leavingItem.role = "out"
        }
        prevLayout = shownLayout; shownLayout = key
        fromH = shownItem ? shownItem.barHeight : 0
        toH = next.barHeight
        shownItem = next; next.frozenH = 0; next.frozenEdge = -1; next.frozenEdgeR = -1; next.role = "in"
        if (!leavingItem || swap === "none" || quiet) { layoutT = 1; pending = null; return }
        layoutT = 0
        // a renderer still building finishes now, on this frame, rather
        // than the swap waiting on a build that may be queued behind others
        if (!next.ready) next.finish()
        if (next.onScreen || !(Window.window && FrameClock.exposed(Window.window.title))) {
            layoutAnim.restart()
        } else pending = next
    }
    // the swap starts once the arriving renderer has been drawn
    Connections {
        target: bar.pending
        function onOnScreenChanged() {
            if (bar.pending && bar.pending.onScreen) { bar.pending = null; layoutAnim.restart() }
        }
    }
    onLayoutChanged: arrive(layout)
    Component.onCompleted: arrive(layout)
    // Warmed once, shortly after the app draws any window: a fixed delay can land
    // after the first swap on a slow startup, and waiting for the mini window's first
    // frame warms at the moment of need. Not restarted when the list re-evaluates
    // (every settings write); a later change warms what is new.
    property bool warmed: false
    function warmAll() {
        warmed = true
        for (const k of warmKeys) if (k && k.length) rendererFor(k)
    }
    onWarmKeysChanged: if (warmed) warmAll()
    Timer { id: warm; interval: 300; onTriggered: bar.warmAll() }
    Connections {
        target: bar.warmed || warm.running ? null : FrameClock
        function onSwapped(title) { warm.restart() }
    }
    Item {
        id: morphClip
        anchors.fill: parent
        clip: true
    }
}
