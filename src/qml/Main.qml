import QtQuick
import QtQuick.Effects
import QtQuick.Window
import Qt5Compat.GraphicalEffects
import Melo 1.0
import "components"
import "components/skeletonmodel.js" as SkeletonModel
import "components/shortcuts.js" as SC
import "views"
import "."

// melo shell: TitleBar / SearchBar / TabBar / [view + QueuePanel] / PlayerBar.
Window {
    // --tilebench <n>: what one MediaTile costs to build, in the running app
    // so every singleton it reads is real. Creates n of them off-screen,
    // reports the total and the per-instance cost, and quits.
    Item {
        id: tileBench
        visible: false
        width: 260; height: 230
        Timer {
            running: Qt.application.arguments.indexOf("--tilebench") >= 0
            interval: 12000; repeat: false
            onTriggered: {
                const i = Qt.application.arguments.indexOf("--tilebench")
                const n = parseInt(Qt.application.arguments[i + 1]) || 100
                const c = Qt.createComponent("components/MediaTile.qml")
                if (c.status !== Component.Ready) { console.warn("[tb] component:", c.errorString()); Qt.quit(); return }
                const made = []
                const t0 = Date.now()
                for (let k = 0; k < n; k++)
                    made.push(c.createObject(tileBench, ({ width: 260, height: 230,
                                                           title_: "x", meta_: "y" })))
                const t1 = Date.now()
                console.warn("[tb] built", made.length, "MediaTiles in", (t1 - t0) + "ms",
                             "=", ((t1 - t0) / Math.max(1, made.length)).toFixed(3) + "ms each")
                // what one tile is actually made of, and which roles it asks for
                if (made.length > 0) {
                    var tally = ({}), roles = [], total = 0
                    function walk(o) {
                        if (!o) return
                        var t = String(o).split("(")[0].split("_QML")[0].replace(/QQuick/, "")
                        tally[t] = (tally[t] || 0) + 1; total++
                        if (t === "Surface" && o.role !== undefined) roles.push(String(o.role))
                        var k = o.children
                        if (k) for (var j = 0; j < k.length; j++) walk(k[j])
                    }
                    walk(made[0])
                    var out = ""
                    for (var key in tally) if (tally[key] > 1 || key.indexOf("Fill") >= 0
                                               || key === "Surface") out += key + "=" + tally[key] + " "
                    console.warn("[tb] one tile: objects=" + total + "  " + out)
                    console.warn("[tb] surface roles:", roles.join(", "))
                }
                const t2 = Date.now()
                for (const m of made) if (m) m.destroy()
                console.warn("[tb] destroy queued in", (Date.now() - t2) + "ms")
                Qt.quit()
            }
        }
    }
    id: root
    // Optional: hold the logical size to the grain at which size * dpr is whole.
    // At a fractional scale Qt stretches the scene onto the rounded buffer, so the
    // effective scale changes with every resize and edges shimmer during a drag.
    // The grain is 120 / gcd(dpr * 120, 120), exact because Wayland expresses the
    // scale in 120ths: 2px at 150%, 10px at 190%, where the stepping is visible,
    // hence a setting.
    // Read on Settings.changed, not bound to uiGet: a function call with no
    // notifying dependency is evaluated once, before Settings has loaded.
    property bool gridSnap: false
    function readGridSnap() { gridSnap = Settings.uiGet("gridSnap", false) === true }
    Connections { target: Settings; function onChanged() { root.readGridSnap() } }
    function snapGrain(d) {
        const n = Math.round(d * 120); let a = n, b = 120
        while (b) { const t = a % b; a = b; b = t }
        return 120 / a
    }
    // Tells GridUi the device ratio so the tile math floors to device pixels (at
    // 200% a logical floor grows a row by two at once). Kept out of snapSize(),
    // which returns early when snap is off, maximised, or at whole scales, and the
    // tiles must still grow smoothly then.
    property bool dprSeen: false
    function pushDpr() {
        if (typeof WindowCtl === "undefined") return
        const d = WindowCtl.dprOf(root)
        if (d > 0) { GridUi.dpr = d; dprSeen = true }
    }
    function snapSize() {
        if (!gridSnap) return
        if (visibility === Window.Maximized || visibility === Window.FullScreen) return
        if (typeof WindowCtl === "undefined") return
        const d = WindowCtl.dprOf(root); if (!(d > 0)) return
        const g = snapGrain(d); if (g <= 1) return
        const w = Math.max(Math.ceil(minimumWidth / g) * g, Math.round(width / g) * g)
        const h = Math.max(Math.ceil(minimumHeight / g) * g, Math.round(height / g) * g)
        if (w !== width) width = w
        if (h !== height) height = h
    }
    Connections { target: root
        function onWidthChanged() { if (!root.dprSeen) root.pushDpr(); root.snapSize() }
        function onHeightChanged() { if (!root.dprSeen) root.pushDpr(); root.snapSize() } }
    onGridSnapChanged: snapSize()
    // Also on a display-scale change (another screen, or the scale changed),
    // which is not a resize. dprOf notifies nothing, so this binds to the counter.
    readonly property int gridGen: typeof WindowCtl !== "undefined" ? WindowCtl.dprGeneration : 0
    onGridGenChanged: { pushDpr(); snapSize() }
    width: 400
    height: 650
    minimumWidth: 384
    minimumHeight: 320
    visible: true
    color: "transparent"
    title: "melo"
    flags: Qt.Window | Qt.FramelessWindowHint

    // Mini bar height; the bar is furniture and scales with the UI. The mini
    // window is exactly its bar, one height per layout: a height that followed the
    // width snapped the window while the bar eased, showing clipped frames and
    // then desktop under it.
    readonly property int barH: Theme.bar(Theme.slotDoc("barMini:" + Theme.barMini, true).height || 77)
    // 0 when maximised or fullscreen: flush with the screen edges, a radius only
    // shows desktop at the corners. Everything rounding the main window reads
    // this; the mini bar and queue card keep their own.
    readonly property int cornerRadius:
        root.visibility === Window.Maximized || root.visibility === Window.FullScreen
            ? 0 : Theme.windowRadius
    // The top corners as they are drawn. The title bar is what fills them, and
    // a rounded rectangle's corner can be no more than half its height: a 24px
    // bar under a 16px radius draws 12. An outline or a ground at the full
    // radius curved outside the bar's own corner, and the bar poked past it.
    readonly property real topCornerRadius: framed && !Theme.borderTitle ? cornerRadius
                                          : Math.min(cornerRadius, (headTitle ? headH : mainTitle.height) / 2)
    // the bottom corners, which a theme may set apart from the top
    readonly property int bottomCornerRadius:
        root.visibility === Window.Maximized || root.visibility === Window.FullScreen
            ? 0 : Theme.windowRadiusBottom
    // ---- the window frame (WindowBorder): a band round the window, or round each
    // part where the border goes round each part. What it frames moves in by
    // its widths; with the title in the frame the title bar spans the band's
    // top and sides, and the band starts under it.
    readonly property bool frameOff: (root.visibility === Window.Maximized || root.visibility === Window.FullScreen)
                                     && !Theme.borderMaximized
    readonly property real frL: frameOff ? 0 : Theme.borderLeft
    readonly property real frT: frameOff ? 0 : Theme.borderTop
    readonly property real frR: frameOff ? 0 : Theme.borderRight
    readonly property real frB: frameOff ? 0 : Theme.borderBottom
    readonly property bool framed: frL > 0 || frT > 0 || frR > 0 || frB > 0
    readonly property bool frameDrawn: framed || (!frameOff && Theme.frameDepth > 0)
    readonly property bool barCard: playerBar.shownBacking === "floating"
    // the bar inside the frame: its own band where the frame goes round each
    // part and it has no card; the window's band otherwise; round the card,
    // the card is what moves in
    readonly property real barInL: borderInParts && barCard ? 0 : frL
    readonly property real barInR: borderInParts && barCard ? 0 : frR
    readonly property real barInB: borderInParts && barCard ? 0 : frB
    readonly property real barRingTop: borderInParts && !barCard ? frT : 0
    readonly property real upperFoot: borderInParts ? frB : 0
    readonly property real contentTop: Theme.borderTitle ? 0 : frT
    readonly property real upperH: height - playerBar.settledHeight - barInB - barRingTop
    // the title bar's corners inside the frame: the band holds the window's
    // curve and the bar the curve left inside it
    readonly property real titleRadiusCap: framed && !Theme.borderTitle ? Math.max(0, cornerRadius - Math.max(frL, frT)) : cornerRadius
    // The header rows that share one surface. With a surface per row, a
    // pattern or a bevel stops and starts again at every seam between the
    // title, the search and the tabs. A theme can draw one surface across all
    // three, or across two of them; the rows in it draw none of their own.
    readonly property bool headTitle: Theme.headerGroup === "all" || Theme.headerGroup === "titleSearch"
    readonly property bool headSearch: Theme.headerGroup !== "separate"
    readonly property bool headTabs: Theme.headerGroup === "all" || Theme.headerGroup === "searchTabs"
    readonly property real headY: headTitle ? 0 : mainTitle.height + (Theme.borderTitle ? frT : 0)
    readonly property real headH: (headTitle ? mainTitle.height : 0) + searchBarRect.height + (headTabs ? tabsSlot.height : 0)
    // Rounded page corners clip the views through a mask of the page shape: the
    // views clip square, so cards ran past the curve. The mask is an offscreen
    // pass, so it runs only while the corners are rounded.
    readonly property real pageFoot: Theme.hasPage && Theme.pageCorners !== "none" ? bottomCornerRadius : 0
    readonly property real pageHead: Theme.hasPage && Theme.pageCorners === "all" ? cornerRadius : 0

    property bool showSearch: true
    // Closing the bar clears what was typed in it. The text drives
    // Library.filter live, so leaving it behind hid the box and left the
    // library filtered by a query with nothing on screen showing it and no
    // way to clear it. Both the button and Ctrl+F come through here.
    onShowSearchChanged: if (!showSearch) searchInput.text = ""
    property bool miniPlayer: false
    // false until the window is positioned at its saved spot (see the
    // settings-loaded handler); gates content so it doesn't flash at KWin's
    // default placement first. Fallback reveals it even if settings never load.
    property bool ready: false
    Timer { running: !root.ready; interval: 500; onTriggered: root.ready = true }
    // last full-mode window size — the mini bg's "preserve in mini" renders the
    // pattern at THIS size and the bar clips a pixel-identical crop of it
    property real lastFullHeight: 600
    property real lastFullWidth: 900
    onReadyChanged: if (ready) applyBlur()   // enable glass once positioned
    // maximise and restore change the corner radius, and the radius is what
    // the glass is rounded to
    onVisibilityChanged: if (ready) applyBlur()
    property bool alwaysOnTop: false

    // transparentHover: the window rests at hoverOpacity while the mouse is away.
    // The fade value animates, not element opacity, so the mini/full flip stays
    // atomic. HoverHandlers sit on the window content root, above every row
    // MouseArea, so child hover grabs cannot flap the state.
    // fadeSnap: hover re-registers on the revealed window a beat after a toggle,
    // so the fade snaps (duration 0) instead of visibly fading in.
    property bool fadeSnap: false
    Timer { id: fadeSnapTimer; interval: 250; onTriggered: root.fadeSnap = false }
    // A compositor drag (startSystemMove) takes the pointer and hover reads
    // false, so the fade holds while dragging. No timeout: a long drag would fade
    // the window in hand. Released by a mouse release reaching the app, KWin's
    // move-finished report, or hover events resuming (compositors without the
    // watcher).
    property bool sysDragging: false
    // every moving fill pauses through a RESIZE — see Theme.held. Not a
    // move: a window being dragged across the screen keeps its size, so
    // its frames cannot lag a configure, and a fill freezing mid-drag
    // read as a hang. sysDragging covers both; resizeFreeze is the resize.
    Binding { target: Theme; property: "held"; value: root.resizeFreeze }
    function holdFadeForDrag() { sysDragging = true }
    // !fadeSnap forces full opacity during the toggle's snap window, because
    // hover re-registers after the flip.
    // Fade trigger per mode: mouse away ("hover") or window inactive ("focus").
    // App-level focus (QGuiApplication::focusWindowChanged): KWin can focus the
    // hidden half of the melo/melo-mini pair, and its active-false may not notify.
    readonly property bool appFocused: WindowCtl.appActive
    readonly property bool fullFadeIdle:
        Theme.fadeMode === "focus" ? !appFocused
      : Theme.fadeMode === "hover" ? !effHovered
      : false
    // root counts as "the mini system" even with the popup closed: the main
    // window IS the taskbar entry, so a taskbar click focuses IT — that must
    // lift the fade
    readonly property bool miniFadeIdle:
        Theme.miniFadeMode === "focus" ? !appFocused
      : Theme.miniFadeMode === "hover" ? !effHovered
      : false
    property real hoverFade:
        fullFadeIdle && !sysDragging && !fadeSnap ? Theme.hoverOpacity : 1
    Behavior on hoverFade { NumberAnimation { duration: root.fadeSnap ? 0 : Theme.hoverFadeMs } }
    property real miniHoverFade:
        miniFadeIdle && !sysDragging && !fadeSnap ? Theme.miniHoverOpacity : 1
    Behavior on miniHoverFade { NumberAnimation { duration: root.fadeSnap ? 0 : Theme.hoverFadeMs } }
    HoverHandler { id: mainHover }

    // search filters (defaults are omitted from the RPC)
    property bool showFilters: false
    property string searchSort: "relevance"
    property string searchType: "any"
    property string searchDate: "any"
    property string searchDuration: "any"
    readonly property bool hasFilters: searchSort !== "relevance" || searchType !== "any"
                                       || searchDate !== "any" || searchDuration !== "any"
    function buildFilters() {
        const f = {}
        if (searchSort !== "relevance") f.sort = searchSort
        if (searchType !== "any") f.type = searchType
        if (searchDate !== "any") f.uploadDate = searchDate
        if (searchDuration !== "any") f.duration = searchDuration
        return f
    }

    // "library-layout": list | grid | compact, shared by all track lists
    property string trackLayout: "grid"
    function changeTrackLayout(mode) {
        trackLayout = mode
        Settings.uiSet("library-layout", mode)
    }
    Connections {   // settings mirror is empty until the sidecar delivers it
        target: Settings
        function onLoadedChanged() {
            root.trackLayout = Settings.uiGet("library-layout", "grid")
            root.refreshShortcuts()
            root.miniPanelH = Number(Settings.uiGet("miniPanelHeight", 400))
            // restore last window size (saved on resize, debounced)
            const w = Settings.uiGet("windowW", 0), h = Settings.uiGet("windowH", 0)
            if (w >= root.minimumWidth && h >= root.minimumHeight) {
                root.width = w
                root.height = h
            }
            // restore position via KWin (clients can't move themselves on
            // Wayland), then start the event-driven geometry watcher — KWin
            // reports once per completed user move/resize, no polling
            const px = Settings.uiGet("windowX", -99999), py = Settings.uiGet("windowY", -99999)
            Qt.callLater(() => {
                if (px !== -99999 && py !== -99999) WindowCtl.applyMainPosition(px, py)
                WindowCtl.watchMainGeometry()
                // reveal content only after the KWin position move — else the
                // window shows at KWin's DEFAULT placement for a frame before
                // it jumps to the saved position
                root.ready = true
            })
            sizeRestored = true
            // apply the saved EQ to the pipeline (window not needed)
            const eq = Settings.uiGet("eqConfig", null)
            if (eq) Player.applyEqConfig(eq)
            // restore volume into melo's OWN state rather than leaving it to
            // PulseAudio stream-restore, or PlayerState boots at 1.0 and the
            // first wheel step jumps to ~100%. Stored on the cubic scale as
            // volumeUi; an old linear "volume" save is converted once
            const savedVol = Settings.uiGet("volumeUi", -1)
            Player.setVolume(savedVol >= 0 ? Number(savedVol)
                                           : Math.cbrt(Number(Settings.uiGet("volume", 1))))
            // restore pin (KWin keepAbove doesn't survive the window going away)
            if (Settings.uiGet("alwaysOnTop", false) === true) {
                root.alwaysOnTop = true
                WindowCtl.setKeepAbove(true)
            }
            // first run: the look, the account, done — once, whether finished or skipped
            if (Settings.uiGet("onboardingDone", false) !== true)
                onboarding.open()
        }
    }

    // persist window size across sessions
    property bool sizeRestored: false
    // Kick the 30s freeze safety on every size: releasing mid-drag restarts
    // animations whose frames lag the configure, and the compositor stretches the
    // last buffer until the motion stops. The safety is a floor for a lost drag only.
    onHeightChanged: { if (resizeFreeze) resizeFreezeSafety.restart()
                       if (!miniPlayer) { sizeSaveTimer.restart()
                                          if (!toggling && !sysDragging && height > 200) lastFullHeight = height } }
    // No blur work on resize: setBlurBehind passes a null region (the whole
    // surface). Re-cutting it per resize forces two extra frames per drag step on
    // the GUI thread (QSG_RENDER_LOOP=basic), which also handles the pointer.
    Connections {
        target: PlayerState
        function onVolumeChanged() { volSaveTimer.restart() }
    }
    Timer {
        id: volSaveTimer
        interval: 500
        onTriggered: if (root.sizeRestored) Settings.uiSet("volumeUi", PlayerState.volume)
    }
    Timer {
        id: sizeSaveTimer
        interval: 400
        onTriggered: {
            // lastFull* updated HERE (post-settle), not per resize step —
            // they feed mini-window bindings and per-step writes would make
            // the sibling churn during the main window's interactive resize
            if (!root.miniPlayer && root.width > 200) root.lastFullWidth = root.width
            if (!root.miniPlayer && root.height > 200) root.lastFullHeight = root.height
            if (!root.sizeRestored || root.visibility === Window.Maximized) return
            // in mini mode the BAR carries the real width
            Settings.uiSet("windowW", root.miniPlayer ? miniWin.width : root.width)
            if (!root.miniPlayer) Settings.uiSet("windowH", root.height)
        }
    }

    // persist window POSITION: KWin's watcher reports geometry over DBus
    // after each completed user move/resize; saved only when it changed
    property int savedX: -99999
    property int savedY: -99999
    Connections {
        target: WindowCtl
        // resize grab steals the pointer -> hover drops -> the hover fade
        // ANIMATES during the resize. Hold the fade like a move-drag.
        function onInteractiveStarted() { root.sysDragging = true; root.resizeFreeze = true }
        // A move holds the fade and nothing else. The grab steals the pointer
        // either way, so the hover fade has to be held or it animates through
        // the drag — but a move changes no size, so there is no configure for a
        // frame to disagree with and nothing to freeze.
        function onInteractiveMoveStarted() { root.sysDragging = true }
        function onMainGeometry(x, y, w, h, cursorInside) {
            root.sysDragging = false   // KWin: interactive move/resize ended
            root.resizeFreeze = false
            root.ensureMainWideEnough()   // popup host after bar resizes
            // no pointer enter is delivered until the mouse MOVES after the
            // grab ends — restore hover from KWin's authoritative answer
            hoverLingerTimer.stop()
            root.effHovered = cursorInside
            // rounded glass region is fixed to the size at apply-time —
            // rebuild it for the new window size after an interactive resize
            if (root.wantBlur && root.cornerRadius > 0) applyBlur()
            if (!root.sizeRestored || root.miniPlayer
                || root.visibility === Window.Maximized) return
            if (!root.miniPlayer && w > 200 && h > 200) {
                root.lastFullWidth = w
                root.lastFullHeight = h
            }
            if (x === root.savedX && y === root.savedY) return
            root.savedX = x
            root.savedY = y
            Settings.uiSet("windowX", x)
            Settings.uiSet("windowY", y)
        }
    }

    // The mini player is a separate bar-sized window. Both windows stay mapped:
    // mapping fires WM open/close animations and loses positions on Wayland.
    // Before each flip KWin moves the invisible counterpart over the visible bar,
    // so the flip reveals it in place.
    // Two client windows cannot swap opacity atomically (a 1-frame gap or double),
    // so with KWin, visibility is per-window opacity for both windows in one
    // script execution and QML opacity carries only the hover fade. Without KWin,
    // QML opacity gates it and the 1-frame seam returns.
    property bool kwinSwap: true
    readonly property real _r: ready ? 1 : 0   // startup position gate
    readonly property real fullContentOpacity: ((kwinSwap || !miniPlayer) ? hoverFade : 0) * _r
    readonly property real fullBaseOpacity: fullContentOpacity
    readonly property real miniContentOpacity: ((kwinSwap || miniPlayer) ? miniHoverFade : 0) * _r
    readonly property bool fullBarVisible: !miniPlayer || toggling
    readonly property bool miniVisible: (miniPlayer || toggling) && builtinMini
    // main is opaque in full mode, and in mini mode while the popup is open (it
    // renders inside main); mini is opaque only in mini mode.
    // shellHidden: a plugin stands in for the compact bar. melo's window is placed
    // as for compact at opacity 0 with input off, and the builtin bar stays down.
    // Cleared whenever the plugin's windows go away, so no plugin can leave the
    // user with an empty screen.
    property bool shellHidden: false
    function setShellHidden(on) {
        if (shellHidden === on) return
        shellHidden = on
        applyWindowOpacity()
        updateMainInput()
    }

    function applyWindowOpacity() {
        const mainOp = shellHidden ? 0 : ((!miniPlayer || miniQueueShown) ? 1 : 0)
        const wins = [{ title: "melo",      opacity: mainOp },
                      { title: "melo-mini",
                        opacity: (miniPlayer && builtinMini && !shellHidden) ? 1 : 0 }]
        // Plugin windows join this call so one KWin script execution swaps them all
        // (see kwinSwap); they report opacity 1 while their host is active.
        if (PluginWindows)
            for (const e of PluginWindows.opacityEntries()) wins.push(e)
        WindowCtl.setWindowOpacities(wins)
    }
    // Compact is first-party, so no plugin can strand the user in a presentation
    // only it could leave.
    // Whether a plugin draws the visualiser; reading `generation` makes this a
    // binding, since qmlFor() is a method. See SlotMap.h.
    readonly property bool vizSlotFilled:
        SlotMap.generation >= 0 && SlotMap.qmlFor("visualizer") !== ""
    readonly property bool queueSlotFilled:
        SlotMap.generation >= 0 && SlotMap.qmlFor("queuePanel") !== ""

    readonly property bool builtinMini: true
    // Input + the folded opacity, in that order and in one call each. Plugin
    // windows are deliberately NOT gated here: they do not live in mini mode.
    function syncPluginMini() {
        WindowCtl.setInputEnabled(miniWin, miniPlayer && builtinMini)
        applyWindowOpacity()
    }

    property bool toggling: false
    // Phase 1: resize the destination window to its target width (waking
    // content mid-resize made KWin stretch the first frame), settle 50ms
    // while the incoming side renders invisibly; Phase 2 = the flip.
    Timer { id: toggleSettleTimer; interval: 50; onTriggered: root.completeToggle() }
    // The bar morphs across the toggle, played by the window being revealed
    // after the flip; waiting on the outgoing bar held the press for a third of a
    // second. The incoming bar sits quiet at the outgoing one's layout while
    // hidden and moves to its own when the flip clears this.
    property string handoverLayout: ""
    // The ground hands over with the controls: the incoming bar starts on the
    // outgoing one's ground too, so the cross-fade runs with the layout's
    // move rather than the new ground being there from the first frame.
    property string handoverBacking: ""
    readonly property string mainLayoutNow: PlayerState.view === 5 ? "barNp:" + Theme.barNp : "barMain:" + Theme.barMain
    readonly property string mainBackingNow: PlayerState.view === 5 ? Theme.backNp : Theme.backMain
    function toggleMini() {
        if (toggling) return
        toggling = true
        fadeSnap = true
        fadeSnapTimer.restart()
        if (!miniPlayer) {
            miniWin.width = width                     // bar takes main's width
            // Align the mini window over main's bar during the settle, not at the flip:
            // on the first collapse it sits at screen centre, and a same-tick move landed
            // after the reveal (a 1-frame flash). The 50ms settle lets the move land.
            WindowCtl.alignForCollapse(root.barH)
        } else {
            width = miniWin.width                     // main expands at the bar's width
        }
        // Enable the incoming window's blur during the settle: KWin gates blur by
        // window opacity, so the flip reveals it with the content. Toggled at the flip
        // it lands a frame late, as a bare-glass frame.
        if (wantBlur) {
            if (miniPlayer) glassOn(root, true)             // expanding -> main incoming
            else if (builtinMini) glassOn(miniWin, true)    // collapsing -> mini incoming
        }
        // The incoming bar starts from the outgoing one's layout and ground, so once
        // revealed it plays the toggle's change. Quiet is set first, since bindings on
        // the same handover re-evaluate in no fixed order.
        const from = miniPlayer ? "barMini:" + Theme.barMini : mainLayoutNow
        const to = miniPlayer ? mainLayoutNow : "barMini:" + Theme.barMini
        playerBar.quiet = miniPlayer      // expanding: main is the one revealed
        miniBar.quiet = !miniPlayer       // collapsing: mini is
        handoverLayout = from !== to ? from : ""
        const fromBack = miniPlayer ? Theme.backMini : mainBackingNow
        const toBack = miniPlayer ? mainBackingNow : Theme.backMini
        handoverBacking = fromBack !== toBack ? fromBack : ""
        // the flip waits only for the window move to land
        toggleSettleTimer.interval = 50
        toggleSettleTimer.restart()
    }
    function completeToggle() {
        // collapse alignment already ran during the settle (see toggleMini);
        // expand aligns main here (its width settled over the last 50ms)
        if (miniPlayer) {
            miniVisWanted = false
            WindowCtl.alignForExpand(root.barH, Math.round(root.width))
        }
        // Who is behind the flip now, set before the state that moves both
        // bars: the one being revealed plays the change, the one going dark
        // lands it. Reversed from the settle, where the revealed bar was the
        // hidden one taking the outgoing layout.
        playerBar.quiet = !miniPlayer     // collapsing: main is the one going dark
        miniBar.quiet = miniPlayer        // expanding: mini is
        miniPlayer = !miniPlayer
        toggling = false
        handoverLayout = ""
        handoverBacking = ""
        // The incoming blur was enabled during the settle; syncMiniQueue's
        // applyBlur() below disables the outgoing one, already at opacity 0.
        // melo, melo-mini and any plugin windows swap in one composite.
        syncPluginMini()
        // Whichever of melo's own two windows is now the visible one. Plugin
        // windows are never activated from here: the shell has no handle to
        // raise one with, and they are not what a mini/full toggle swaps.
        if (!miniPlayer) root.requestActivate()
        else if (builtinMini) miniWin.requestActivate()
        syncMiniQueue()
    }
    // A file handed to melo: by the desktop entry's MimeType, by `melo <path>`,
    // or by a second launch passing its arguments to this one over MPRIS.
    // Local files are imported the same way the Settings importer does it and
    // then played; anything else goes to the player as a URI.
    function openExternalUri(uri) {
        if (!uri) return
        const s = String(uri)
        if (s.startsWith("file://")) {
            const path = decodeURIComponent(s.substring(7))
            sidecar.rpc("library/importFiles", { paths: [path] }, (res) => {
                // the callback gets { ok, result }
                const ts = res && res.ok && res.result ? res.result.tracks : null
                const t = ts && ts.length ? ts[0] : null
                if (t) Player.playTrackData(t)
            })
        } else {
            // A URL or a search term: put it in the search field and run the
            // same path Enter does, rather than a second one that can drift.
            searchInput.text = s
            searchInput.accepted()
        }
        root.requestActivate()
    }

    Component.onCompleted: {
        // Once at startup, or it never runs at all: the window opens at the
        // size it was saved with, so nothing resizes it, and dprGeneration
        // cannot fire either -- its event filter arms on the first dprOf call,
        // which only happens in here.
        root.readGridSnap()
        root.snapSize()
        root.refreshShortcuts()
        kwinSwap = WindowCtl.kwinAvailable()
        WindowCtl.setInputEnabled(miniWin, false)
        applyWindowOpacity()   // full mode: main opaque, mini transparent
        applyBlur()
        // Pre-place the mini window under main's bar at startup; otherwise its first
        // reveal is its first map and KWin cascade-places it for a frame. Retried over
        // ~1s because alignForCollapse is a no-op until KWin has mapped it.
        prewarmTimer.start()
    }
    property int prewarmTries: 0
    Timer {
        id: prewarmTimer
        interval: 120; repeat: true
        onTriggered: {
            // the KWin script can't report window-found back synchronously,
            // so just re-place a fixed number of times across the first ~1s —
            // by then both windows are mapped and a late retry lands. Stop if
            // the user toggles first (don't move the mini out from under them).
            if (root.miniPlayer || root.toggling || ++root.prewarmTries > 8) { stop(); return }
            // Re-assert opacity too: the onCompleted applyWindowOpacity() can race
            // mapping and leave mini at KWin's default opacity 1, doubling the bar on the
            // first collapse.
            WindowCtl.alignForCollapse(root.barH)
            applyWindowOpacity()
        }
    }
    // Do not gate root.contentItem.visible for mini-mode silence: the render root
    // does not reliably repaint when shown again and leaves the transparent buffer
    // up. Silence comes from item-level gates, the viz pumpOn_ and the severed
    // overlay binding.

    // The mini-mode queue popup is not a separate window: KWin aligns the
    // always-mapped main window's bar under the mini bar, and only its queue
    // overlay is revealed and input-masked. A KWin glue keeps it aligned during
    // drags.
    property bool miniQueueShown: false
    // the popup region hosts EITHER the queue or the mini visualizer
    property bool miniVisWanted: false
    // the popup renders inside MAIN, so main must be at least as wide as
    // the bar; asserted at cheap moments (popup open, bar-resize end)
    function ensureMainWideEnough() {
        if (miniPlayer && width < miniWin.width) width = miniWin.width
    }
    function syncMiniQueue() {
        const want = miniPlayer && PlayerState.hasTrack
                     && (PlayerState.showPanel || miniVisWanted)
        if (want) ensureMainWideEnough()
        if (want && !miniQueueShown) {
            WindowCtl.alignForExpand(root.barH, Math.round(root.width))           // blocking; invisible while it happens
            WindowCtl.setMiniQueueGlue(true)       // follow bar drags
        } else if (!want && miniQueueShown) {
            WindowCtl.setMiniQueueGlue(false)
        }
        miniQueueShown = want
        applyWindowOpacity()   // popup open needs main opaque (it renders there)
        updateMainInput()
    }
    function updateMainInput() {
        if (shellHidden) {
            WindowCtl.setInputEnabled(root, false)
        } else if (!miniPlayer) {
            WindowCtl.setInputEnabled(root, true)
        } else if (miniQueueShown) {
            WindowCtl.setInputRegion(root, 0, miniQueueOverlay.y,
                                     miniQueueOverlay.width, miniQueueOverlay.height)
        } else {
            WindowCtl.setInputEnabled(root, false)
        }
        applyBlur()   // blur follows the same visibility state
    }
    Connections {
        target: PlayerState
        function onShowPanelChanged() { root.syncMiniQueue() }
        function onTrackChanged() { root.syncMiniQueue() }
    }

    // Pure moves require equal widths: mini tracks main's width while hidden —
    // DEBOUNCED: resizing the second (invisible) surface on every frame of an
    // interactive side-drag makes the main window's resize stutter.
    onWidthChanged: {
        if (resizeFreeze) resizeFreezeSafety.restart()   // see onHeightChanged
        // MELO_GEOM_DEBUG=1 traces every width the main window takes and what
        // state it was in
        if (MELO_GEOM_DEBUG)
            console.warn("[geom] main w=" + Math.round(width) + " h=" + Math.round(height)
                         + " mini=" + miniPlayer + " toggling=" + toggling + " dragging=" + sysDragging
                         + " lastFull=" + Math.round(lastFullWidth) + " screen=" + Screen.width)
        if (!miniPlayer) { miniSyncTimer.restart(); sizeSaveTimer.restart()
                           if (!toggling && !sysDragging && width > 200) lastFullWidth = width }
    }
    Timer {
        id: miniSyncTimer
        interval: 200
        onTriggered: if (!root.miniPlayer) miniWin.width = root.width
    }

    // KWin blur is a surface property, so a transparent mapped window still
    // blurs; blur follows the visible window (in mini-queue mode, only the queue
    // overlay's rect on main). glassBlur: off / always / hover / away.
    // effHovered drives both fade and blur: instant on enter, held for
    // glassHoverDelay after leaving so the two release together.
    // Also counted as hovered: in mini mode the popup in main, an open context
    // menu (its own window, outside both HoverHandlers), and an open modal.
    readonly property bool rawHovered:
        (miniPlayer ? (miniHover.hovered || (miniQueueShown && mainHover.hovered))
                    : mainHover.hovered)
        || contextMenu.visible || metadataEditor.visible
        || playlistFlyout.visible || promptDialog.visible || onboarding.visible
    property bool effHovered: false
    onRawHoveredChanged: {
        if (rawHovered) {
            sysDragging = false   // hover events flowing again = drag is over
            hoverLingerTimer.stop()
            effHovered = true
        } else {
            // During a toggle the handler flips to the other window's HoverHandler before
            // its enter arrives; this stale false dipped the revealed window for a frame.
            // The next real mouse event or cursorInside report re-asserts the state.
            if (toggling || fadeSnap) return
            if (Theme.glassHoverDelay > 0) hoverLingerTimer.restart()
            else effHovered = false
        }
    }
    Timer {
        id: hoverLingerTimer
        interval: Math.max(1, Theme.glassHoverDelay)
        onTriggered: root.effHovered = false
    }
    // focus-triggered variants share the fade's notion of "the mini system
    // is focused": the bar or its popup being active counts
    readonly property bool sysFocused: appFocused
    function blurWanted(hovered) {
        // the WINDOW's own alpha, not the master: a theme can be see-through
        // through a role's opacity alone
        if (!Theme.translucent("window")) return false
        if (Theme.glassBlur === "always") return true
        if (Theme.glassBlur === "hover") return hovered || sysDragging
        if (Theme.glassBlur === "away") return !hovered && !sysDragging
        if (Theme.glassBlur === "focus") return sysFocused
        if (Theme.glassBlur === "unfocus") return !sysFocused
        return false
    }
    readonly property bool wantBlur: blurWanted(effHovered)
    onWantBlurChanged: applyBlur()
    // a contrast the compositor can only apply through the blur effect has
    // to re-ask for that effect when it changes
    Connections { target: Theme; function onWantContrastChanged() { root.applyBlur() } }
    function glassOn(w, on) {
        WindowCtl.setBlurBehind(w, on)
        WindowCtl.setBackgroundContrast(w, on, Theme.glassContrast, Theme.glassSaturation)
    }
    function applyBlur() {
        if (MELO_FOCUS_DEBUG) console.log("[focus-debug] applyBlur wantBlur", wantBlur,
                                          "mode", Theme.glassBlur, "ready", ready)
        // no glass until the window is positioned — the blurred backing would
        // otherwise show at KWin's DEFAULT placement for a frame or two before
        // the window moves ("spawns in the wrong space")
        if (!ready) { glassOn(root, false); glassOn(miniWin, false); return }
        WindowCtl.setBlurRadius(root.cornerRadius)   // 0 when maximised
        glassOn(miniWin, (wantBlur || Theme.wantContrast) && miniPlayer && builtinMini)
        // Contrast needs glass: Plasma 6.5 merged background contrast into the blur
        // effect, so a surface that requests no blur gets no contrast. A non-default
        // contrast therefore requests blur too, at KWin's global strength.
        if (!wantBlur && !Theme.wantContrast) { glassOn(root, false); return }
        if (!miniPlayer) glassOn(root, true)
        else if (miniQueueShown) {
            WindowCtl.setBlurRegion(root, 0, miniQueueOverlay.y,
                                    miniQueueOverlay.width, miniQueueOverlay.height)
            WindowCtl.setBackgroundContrast(root, true, Theme.glassContrast, Theme.glassSaturation)
        } else glassOn(root, false)
    }
    Connections {   // re-apply when the glass knobs move
        target: ThemeBackend
        function onThemeChanged() { root.applyBlur() }
    }

    // Everything in the main window sits under this gate. `visible` too:
    // opacity-0 content still commits frames (60 swaps/s during bar resizes), and
    // a sibling committing mid-resize breaks KWin's commit/configure pairing.
    Item {
        id: mainContent
        anchors.fill: parent
        // window bg stands in on collapse (underlayer for the full bar) and
        // appears immediately on expand — fullBarVisible covers both covers
        visible: root.fullBarVisible
        opacity: root.fullBaseOpacity
        // The window's own ground, a Surface so Base can be a blend mode; at the
        // bottom of the scene it blends against whatever the compositor drew. z puts
        // it under or over the artwork: over, the window colour washes the picture
        // and adaptive has a real backdrop to sample.
        // `ground` composites artwork and window colour into one texture, because a
        // shader cannot read the framebuffer and an adaptive surface must be handed
        // what is beneath it as an item. Layered only when something adapts: it is a
        // full-window offscreen pass.
        Item {
            id: ground
            anchors.fill: parent
            z: 0
            // ...and only while something is reading it. The palette scan says
            // a role COULD adapt; the count says one is on screen now.
            layer.enabled: Theme.anyAdaptive && Theme.adaptiveUsers > 0
            Component.onCompleted: Theme.backdrop = ground

            Surface {
                anchors.fill: parent
                role: "window"
                z: Theme.windowOverBackground ? 1 : 0
                // Its own backdrop is the artwork, never `ground` — that is
                // the item it is inside, and a source that contains its own
                // reader is a loop the scene graph resolves as an empty
                // texture.
                backdrop: Theme.windowOverBackground ? bgLayer : null
                radius: root.cornerRadius
                topLeftRadius: root.topCornerRadius; topRightRadius: root.topCornerRadius
                bottomLeftRadius: root.bottomCornerRadius; bottomRightRadius: root.bottomCornerRadius
            }
            // theme background (orbs/gradient/image) — on the translucent base,
            // behind the views (which are separate siblings drawn on top).
            // hold: no repaints during interactive move/resize (jitter otherwise)
            BackgroundLayer {
                id: bgLayer
                anchors.fill: parent
                z: 0
                hold: root.sysDragging
                // Rounded to the ground's cornerRadius, which this covers with square
                // corners. Masked only when there are corners; with a blurred image background
                // this is one more pass, not the first.
                layer.enabled: root.cornerRadius > 0
                layer.effect: OpacityMask {
                    maskSource: Item {
                        width: bgLayer.width
                        height: bgLayer.height
                        Rectangle { anchors.fill: parent; radius: root.cornerRadius
                                    bottomLeftRadius: root.bottomCornerRadius; bottomRightRadius: root.bottomCornerRadius }
                    }
                }
                // Always the stable lastFull* size, bottom-left anchored: switching to the
                // live width on `toggling` ran ahead of the window geometry. When idle,
                // lastFull* equals width/height.
                renderW: root.lastFullWidth
                renderH: root.lastFullHeight
                renderY: height - root.lastFullHeight
            }
        }   // ground
    }

    // mini-mode queue: rendered by the (otherwise invisible) main window,
    // sitting exactly above where the mini bar overlaps main's bar region
    Shortcut {
        sequence: "Escape"
        enabled: root.miniQueueShown
        onActivated: { PlayerState.showPanel = false; root.miniVisWanted = false }
    }
    // popup height is user-resizable (top-edge drag) and persisted
    property int miniPanelH: 400
    Timer {
        id: panelHSaveTimer
        interval: 800
        onTriggered: Settings.uiSet("miniPanelHeight", root.miniPanelH)
    }
    Item {
        id: miniQueueOverlay
        visible: root.miniQueueShown
        // the popup fades with the bar (shared mini hover state)
        opacity: root.miniPlayer ? root.miniHoverFade : 1
        anchors.left: parent.left
        // width follows the BAR live — but ONLY while shown: a hidden overlay tracking the bar per drag
        // frame re-layouts its ListView, and the polish request schedules
        // real (empty) frames on main — sibling chatter during the resize
        width: !root.miniQueueShown ? 400
             : root.miniPlayer ? (root.miniLeftResizeHold ? root.miniBarWFrozen : miniWin.width)
             : root.width
        // a SEPARATE rounded card: a small gap above the bar (only when the
        // corners are rounded — squared themes stay flush/continuous)
        readonly property int gap: root.cornerRadius > 0 ? 6 : 0
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.barH + gap
        height: Math.max(120, Math.min(root.miniPanelH, root.height - root.barH - gap))
        z: 60
        // BLUR region tracks the popup per frame (a lagging glass backing
        // trails the edges visibly); the INPUT mask stays debounced — mask
        // rewrites mid-drag stalled the event stream, blur rewrites don't
        // affect input delivery.
        function trackRegions() {
            if (!root.miniQueueShown) return
            if (root.wantBlur) {
                if (MELO_GEOM_DEBUG)
                    console.warn("[geom] blur region y=" + Math.round(y) + " " + Math.round(width)
                                 + "x" + Math.round(height) + " mainW=" + Math.round(root.width))
                WindowCtl.setBlurRegion(root, 0, y, width, height)
            }
            regionSyncTimer.restart()
        }
        onHeightChanged: trackRegions()
        onWidthChanged: trackRegions()
        onYChanged: trackRegions()
        Timer {
            id: regionSyncTimer
            interval: 150
            // Final region once the popup settles: a change during an in-flight commit,
            // or a binding settling a frame after the drag, otherwise leaves the blur
            // behind with nothing to correct it.
            onTriggered: if (root.miniQueueShown) {
                if (root.wantBlur)
                    WindowCtl.setBlurRegion(root, 0, miniQueueOverlay.y,
                                            miniQueueOverlay.width, miniQueueOverlay.height)
                root.updateMainInput()
            }
        }

        MouseArea {   // top-edge height drag
            id: panelHandle
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 10
            z: 10
            hoverEnabled: true
            cursorShape: Qt.SizeVerCursor
            onPositionChanged: (m) => {
                if (!pressed) return
                const gy = mapToItem(root.contentItem, m.x, m.y).y
                root.miniPanelH = Math.max(120,
                    Math.min(root.height - root.barH, (root.height - root.barH) - gy))
                panelHSaveTimer.restart()
            }
            onReleased: root.updateMainInput()   // final exact region
            Rectangle {   // grip affordance
                anchors.horizontalCenter: parent.horizontalCenter
                y: 3
                width: 36; height: 4; radius: Theme.pill(2)
                color: panelHandle.containsMouse || panelHandle.pressed
                       ? Theme.borderStrong : Theme.border
                // over the visualizer the grip fades unless hovered, like
                // the gear (queue mode keeps it always on — it reads as
                // part of the list chrome there)
                opacity: !root.miniVisWanted || overlayHover.hovered || panelHandle.pressed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }
        }
        HoverHandler { id: overlayHover }
        QueuePanel {
            anchors.fill: parent
            visible: !root.miniVisWanted
            fullWidth: true
            miniHost: true
            contextMenu: contextMenu   // main-window overlays work in mini mode
        }
        Surface {   // visualizer popup backing (the shared viz reparents in)
            id: miniVisSlot
            anchors.fill: parent
            visible: root.miniVisWanted
            role: "window"
            // All corners rounded: the projectM FBO cannot be corner-masked on this GPU
            // (a layer mask artifacted), so the viz is inset by the radius and this card
            // frames it.
            radius: Theme.windowRadius
            // the appearance window-border outline on the visualizer card
            borderRole: Theme.windowBorder ? "windowBorder" : ""
            borderWidth: Theme.windowBorder ? Theme.windowBorderWidth : 0
        }
    }

    Window {
        id: miniWin
        onActiveChanged: if (MELO_FOCUS_DEBUG)
            console.log("[focus-debug] miniWin.active", active)
        transientParent: root
        width: 1000     // kept in sync with main while hidden (pure-move constraint)
        height: root.barH
        minimumWidth: 320
        color: "transparent"
        title: "melo-mini"    // distinct title (bg-rule exclusion, future rules)
        flags: Qt.Window | Qt.FramelessWindowHint
        visible: true

        HoverHandler { id: miniHover; enabled: root.miniPlayer }
        WindowShape {
            id: miniShape
            parent: miniWin.contentItem
            anchors.fill: parent
            z: 10000000
            spec: Theme.shapeFor(Theme.windowRadius, Theme.windowRadius)
            active: spec !== null
        }
        // WIDTH resize via the bar's own edges (KWin native resize); the
        // main window's width follows below, which keeps the popup and the
        // collapse/expand pure-move constraint in sync automatically
        // The bar's width grabs, along the shape's edge wherever it runs
        MouseArea {
            visible: root.miniPlayer
            anchors.fill: parent
            z: 950
            hoverEnabled: true
            containmentMask: miniShape.edgeRing
            acceptedButtons: Qt.LeftButton
            function sideAt(x) {
                const n = miniShape.edgeNormalAt(x, height / 2)
                return n.x < -0.35 ? Qt.LeftEdge : n.x > 0.35 ? Qt.RightEdge : 0
            }
            cursorShape: containsMouse && sideAt(mouseX) ? Qt.SizeHorCursor : Qt.ArrowCursor
            onPressed: (m) => {
                const e = sideAt(m.x)
                if (!e) { m.accepted = false; return }
                if (e === Qt.LeftEdge) {
                    root.miniBarWFrozen = miniWin.width
                    root.miniLeftResizeHold = true
                }
                root.beginResizeHold()
                miniWin.startSystemResize(e)
                m.accepted = true
            }
        }
        // Popup CLOSED: bar resizes touch nothing (the open-time ensure
        // covers the host width). Popup OPEN: main must track live or the
        // popup clips mid-drag and leaps out on release — affordable
        // because the heavy full-mode content is visible:false in mini.
        onWidthChanged: if (root.miniPlayer) {
            if (root.miniQueueShown && root.width < width) root.width = width
            sizeSaveTimer.restart()
            // same growing-lag as the full window: rebuild the mini bar's
            // rounded blur region live so the glass tracks the widening edge
            if (root.wantBlur && Theme.windowRadius > 0)
                WindowCtl.setBlurBehind(miniWin, true)
        }
        // same stack as the full window (base layer UNDER the bar's
        // bgElevated) — without it the mini bar reads more transparent
        // than the full bar
        Surface {
            anchors.fill: parent
            role: "window"
            radius: Theme.windowRadius
            visible: root.miniVisible
            opacity: root.miniContentOpacity
        }
        // Theme background behind the mini bar, animating only in mini mode so it
        // never runs alongside the full-mode instance. "Preserve in mini" renders at
        // full-window height, top-anchored, so patterns are not squished.
        BackgroundLayer {
            miniMode: true
            hold: root.sysDragging
            anchors.fill: parent
            // 'preserve in mini' = render the pattern at the FULL window size
            // and let the bar clip a pixel-identical crop of it: bottom-aligned
            // (the mini bar is the player-bar region at the window bottom) and
            // horizontally centred. Off = fill the bar (squashed).
            readonly property bool _preserve: !!(Theme.background && Theme.background.preserveInMini)
            renderW: _preserve ? root.lastFullWidth : width
            renderH: _preserve ? root.lastFullHeight : height
            renderX: 0   // left-aligned, matching the full instance's anchor
            renderY: _preserve ? (height - root.lastFullHeight) : 0
            visible: root.miniVisible && !(Theme.background && Theme.background.showInMini === false)
            opacity: root.miniContentOpacity
        }
        // The frame round the mini player (WindowBorder): round its window, the bar
        // moved in by the band; or round its floating card where the theme
        // frames each part
        WindowBorder {
            readonly property bool card: Theme.windowBorderFit === "parts" && miniBar.shownBacking === "floating"
            x: card ? miniBar.inset - root.frL : 0
            y: card ? miniBar.cardTop - root.frT : 0
            width: card ? parent.width - 2 * miniBar.inset + root.frL + root.frR : parent.width
            height: card ? parent.height - miniBar.cardTop - miniBar.cardBottom + root.frT + root.frB : parent.height
            borderLeft: root.frL; borderTop: root.frT; borderRight: root.frR; borderBottom: root.frB
            radiusTL: card ? Theme.radiusLg + Math.max(root.frL, root.frT) : Theme.windowRadius
            radiusTR: card ? Theme.radiusLg + Math.max(root.frR, root.frT) : Theme.windowRadius
            radiusBL: card ? Theme.radiusLg + Math.max(root.frL, root.frB) : Theme.windowRadiusBottom
            radiusBR: card ? Theme.radiusLg + Math.max(root.frR, root.frB) : Theme.windowRadiusBottom
            shape: !card && miniShape.active ? miniShape : null
            visible: root.frameDrawn && root.miniVisible && height > 0
            opacity: root.miniContentOpacity
            z: 900
            readonly property bool framesWindow: !card
        }
        PlayerBar {
            id: miniBar
            objectName: "miniBar"
            barMenu: (sx, sy, host) => root.openBarMenu(sx, sy, host)
            dismissMenus: () => contextMenu.close()
            anchors.fill: parent
            // inside a frame round the mini window; a framed card moves in itself
            readonly property bool framedWindow: !(Theme.windowBorderFit === "parts" && shownBacking === "floating")
            // A shaped window is filled, not inset: the shape cuts the
            // backing and the frame is drawn over it, where a backing inset by
            // the frame left the cut corners empty
            readonly property bool shaped: miniShape.active && miniShape.hasShape
            anchors.leftMargin: framedWindow && !shaped ? root.frL : 0
            anchors.topMargin: framedWindow && !shaped ? root.frT : 0
            anchors.rightMargin: framedWindow && !shaped ? root.frR : 0
            anchors.bottomMargin: framedWindow && !shaped ? root.frB : 0
            edgeRadius: shaped ? 0
                      : framedWindow ? Math.max(0, Theme.windowRadius - Math.max(root.frL, root.frT, root.frR, root.frB)) : Theme.windowRadius
            mini: true
            cutLeft: shaped ? Math.max(root.frL, root.miniCutL) : 0
            cutRight: shaped ? Math.max(root.frR, root.miniCutR) : 0
            layout: root.handoverLayout.length && !root.miniPlayer ? root.handoverLayout : "barMini:" + Theme.barMini
            backing: root.handoverBacking.length && !root.miniPlayer ? root.handoverBacking : Theme.backMini
            // What the main window may hand over, both of them: this bar
            // starts the collapse on whichever layout main was showing, and
            // building the now-playing one at the toggle was thirteen cells
            // inside the settle — the stutter on the way into the mini player.
            warmKeys: ["barMain:" + Theme.barMain, "barNp:" + Theme.barNp]
            // silent when hidden; renders during the settle (miniVisible)
            visible: root.miniVisible
            opacity: root.miniContentOpacity
            holdAnims: root.sysDragging
            miniActive: root.miniPlayer
            eqActive: eqLoader.item ? eqLoader.item.visible : false
            visActive: root.miniVisWanted
            onQueueToggle: CommandMap.invoke("toggleQueue")
            onVisToggle: CommandMap.invoke("toggleVisualizer")
            onEqToggle: CommandMap.invoke("toggleEq")
            onDragStarted: root.holdFadeForDrag()
        }
        Shortcut { sequence: "Escape"; enabled: root.miniPlayer; onActivated: CommandMap.invokeGesture("compact.escape") }
    }

    // Popup-as-subsurface of the bar is WORSE than the toplevel popup: Qt
    // subsurfaces are desynchronized, so the child's commits collide with the
    // parent's resize inside one composited unit (tearing).

    // ---------- layout (opacity-gated by mini state; window never unmaps) ----------
    PlayerBar {
        barMenu: (sx, sy, host) => root.openBarMenu(sx, sy, host)
        dismissMenus: () => contextMenu.close()
        // the now-playing page shows the track at every size the bar could;
        // its transport is the only part not already on screen
        objectName: "playerBar"
        // never the handover's: see PlayerBar.settleLayout
        settleLayout: root.mainLayoutNow
        // inert while arranged: the arranger's handles take every press
        enabled: !Theme.arranging
        // Layout: the handover's while it runs (collapsing, this bar plays it;
        // expanding, it lands on it quiet, so the flip has nothing to animate); the
        // mini slot's while mini is up, so the way back starts from what was shown;
        // the arranged slot while arranging; else barView's.
        layout: root.handoverLayout.length && root.miniPlayer ? root.handoverLayout
              : root.miniPlayer ? "barMini:" + Theme.barMini
              : Theme.arranging ? Theme.arrangeSlot + ":" + String(ThemeBackend.settings[Theme.arrangeSlot] || (Theme.arrangeSlot === "barNp" ? "centre" : "rows"))
              : (root.barView === 5 ? "barNp:" + Theme.barNp : "barMain:" + Theme.barMain)
        backing: Theme.arranging ? (Theme.arrangeSlot === "barNp" ? Theme.backNp : Theme.arrangeSlot === "barMini" ? Theme.backMini : Theme.backMain)
               : root.handoverBacking.length && root.miniPlayer ? root.handoverBacking
               : (root.barView === 5 ? Theme.backNp : Theme.backMain)
        mini: Theme.arranging && Theme.arrangeSlot === "barMini"
        customising: Theme.arranging
        // the layouts the swaps to come will want, built at idle
        warmKeys: ["barNp:" + Theme.barNp, "barMain:" + Theme.barMain, "barMini:" + Theme.barMini]
        id: playerBar
        // The bar fills a shaped window, and its rows start inside the cut
        cutLeft: root.shaped ? root.cutBarL : 0
        cutRight: root.shaped ? root.cutBarR : 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.shaped ? 0 : root.barInL
        anchors.rightMargin: root.shaped ? 0 : root.barInR
        anchors.bottomMargin: root.shaped ? 0 : root.barInB
        // its window-edge corners: what is left of the window's inside the band
        edgeRadius: root.shaped ? 0
                  : Math.max(0, root.bottomCornerRadius - Math.max(root.barInL, root.barInR, root.barInB))
        z: 10   // volume toast pops above the bar into view territory
        // silent when hidden; renders during the settle (fullBarVisible)
        visible: root.fullBarVisible
        opacity: root.fullContentOpacity
        holdAnims: root.sysDragging
        miniActive: root.miniPlayer
        eqActive: eqLoader.item ? eqLoader.item.visible : false
        onQueueToggle: CommandMap.invoke("toggleQueue")
        onEqToggle: CommandMap.invoke("toggleEq")
        onDragStarted: root.holdFadeForDrag()
    }

    // The arranger, over the bar while arranging. Built on first use, since Qt
    // walks every item, hidden or not, on each polish
    // (QQuickWindowPrivate::updateChildWindowStackingOrder) and this is 18% of the
    // window's tree. Kept once built: `arranging` flips while you work.
    Loader {
        id: barArrange
        anchors.fill: playerBar
        z: 11
        property bool everOpened: false
        active: Theme.arranging || everOpened
        onActiveChanged: if (active) everOpened = true
        visible: Theme.arranging && root.fullBarVisible
        sourceComponent: BarArrange { bar: playerBar }
    }
    // Through the loader's item, which is null until it is opened.
    Binding { target: playerBar; property: "docOverride"
              value: barArrange.item ? barArrange.item.previewDoc : null
              when: Theme.arranging && barArrange.item !== null }
    function startArrange(slot) { Theme.arrangeSlot = slot || "barMain"; Theme.arranging = true }
    // the view the bar draws for: the now-playing view once its page has
    // been drawn — Qt's frameSwapped after it turned visible — any other at once
    readonly property int barView: PlayerState.view === 5 && !(npLoader.item && npLoader.item.onScreen) ? root.lastOtherView : PlayerState.view
    property int lastOtherView: PlayerState.view === 5 ? 1 : PlayerState.view
    Connections { target: PlayerState; function onViewChanged() { if (PlayerState.view !== 5) root.lastOtherView = PlayerState.view } }

    Surface {   // the header rows' shared surface, when the theme groups them
        x: root.shaped || (root.headTitle && Theme.borderTitle) ? 0 : root.frL
        y: root.headY + root.contentTop
        width: parent.width - x - (root.shaped || (root.headTitle && Theme.borderTitle) ? 0 : root.frR)
        height: root.headH
        visible: Theme.headerGroup !== "separate" && root.fullBarVisible && height > 0
        opacity: root.fullBaseOpacity
        role: root.headTitle ? "title" : "chrome"
        backdrop: ground
        topLeftRadius: root.headTitle ? root.topCornerRadius : 0
        topRightRadius: root.headTitle ? root.topCornerRadius : 0
    }
    Column {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // Anchored to where the bar ends up, not its animating top edge, which
        // re-laid the whole column every frame of a layout change.
        anchors.bottom: parent.bottom
        anchors.bottomMargin: playerBar.settledHeight + root.barInB + root.barRingTop + root.upperFoot
        anchors.topMargin: root.contentTop
        opacity: root.fullBaseOpacity   // appears immediately on expand
        // NOT laid out in mini: opacity-0 content still pays full layout
        // cost, and with the popup open main resizes per drag frame — the
        // views must not relayout along. fullBarVisible = false in plain mini
        // (no relayout) but true through the 100ms collapse cover.
        visible: root.fullBarVisible
        clip: true

        TitleBar {
            id: mainTitle
            showAccount: true
            // Same flow as the settings window's New button, and it switches
            // to what it just made — picking "New profile…" from a list of
            // identities is a request to use one, not only to have one.
            onNewProfileRequested: promptDialog.promptDialog("New profile name", "", (name) => {
                if (!name || !name.trim()) return
                const n = name.trim()
                sidecar.rpc("cookies/create", { name: n }, () => {
                    Settings.cookieProfile = n
                    Settings.cookieSource = "guest"
                })
            })
            backdrop: ground
            // The title runs to the frame as every other band of the window
            // does, and its own contents come in by the cut. Inset whole, it
            // stopped short of the border while the search row beside it did
            // not, and the window showed through the step between them.
            readonly property bool fills: Theme.borderTitle || root.shaped
            cutLeft: root.cutTitleL - (fills ? 0 : root.frL)
            cutRight: root.cutTitleR - (fills ? 0 : root.frR)
            ground: !root.headTitle
            radiusCap: root.shaped ? root.cornerRadius : root.titleRadiusCap
            x: fills ? 0 : root.frL
            width: parent.width - (fills ? 0 : root.frL + root.frR)
            pinned: root.alwaysOnTop
            searchActive: root.showSearch
            settingsActive: settingsLoader.item ? settingsLoader.item.visible : false
            onDragStarted: root.holdFadeForDrag()
            // a plain click starts no move session and KWin never reports
            // an end, so the release clears the drag-hold
            onDragReleased: root.sysDragging = false
            onPinToggle: CommandMap.invoke("togglePin")
            onSearchToggle: CommandMap.invoke("toggleSearch")
            onSettingsToggle: CommandMap.invoke("openSettings")
        }

        // the band between a title bar in the frame and what follows it
        Item { width: 1; height: Theme.borderTitle ? root.frT : 0 }
        // search bar
        Rectangle {
            id: searchBarRect
            x: root.shaped ? 0 : root.frL
            width: parent.width - (root.shaped ? 0 : root.frL + root.frR)
            // The row is as tall as what it holds plus the same air above and
            // below; the field and the toggle sit centred in it.
            // ...and the field grows by the input's top and bottom inset
            readonly property int fieldH: 28 + Theme.inset("input", "top") + Theme.inset("input", "bottom")
            // the air above and below is the header's inset, and what the row
            // holds sits centred between the two — an inset is a rule about
            // the edge, so an uneven pair moves the field with it
            readonly property int topPad: Theme.inset("header", "top")
            readonly property int botPad: Theme.inset("header", "bottom")
            function yFor(h) { return topPad + (rowH - topPad - botPad - h) / 2 }
            readonly property int rowH: Math.max(fieldH, Theme.ctl(28)) + topPad + botPad
            // The row runs to the frame and what sits on it starts inside,
            // as in every other band of the window: the row is the surface,
            // so the field, the filter toggle and the filter row each owe the
            // cut on top of their own inset.
            readonly property real cutL: root.shaped ? root.cutLOf(searchBarRect) : 0
            readonly property real cutR: root.shaped ? root.cutROf(searchBarRect) : 0
            height: root.showSearch ? (root.showFilters ? rowH + 30 : rowH) : 0
            // One row or two: a theme may put the tabs beside the search — the
            // tab bar moves in here, at the left, and the field takes the rest
            readonly property bool combined: root.showSearch && Theme.headerCanCombine(width, tabBar.implicitWidth)
            visible: height > 0
            color: "transparent"
            clip: true

            Surface {
                anchors.fill: parent
                z: -1
                visible: !root.headSearch
                role: "chrome"
                backdrop: ground
            }

            Behavior on height {
                NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
            }

            // filter toggle
            Surface {
                id: filterToggle
                y: searchBarRect.yFor(height)
                anchors.right: parent.right
                anchors.rightMargin: Theme.inset("header", "right") + searchBarRect.cutR
                width: Theme.iconBtn; height: Theme.iconBtn
                radius: Theme.radiusMd
                // a framed button, as every other one: the field with a
                // border at rest, the hover surface under the pointer, the
                // active face while the filter row is open, the accent border
                // when a filter is set
                role: Theme.faceOf("button", ftMa.containsMouse, ftMa.pressed, root.showFilters)
                borderWidth: 1
                borderRole: root.hasFilters ? "accent"
                          // open already: the pointer does not brighten its edge
                          : (ftMa.containsMouse && !root.showFilters) ? "borderStrong" : "border"
                Icon {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: Theme.pressShift(ftMa.pressed)
                    anchors.verticalCenterOffset: Theme.pressShift(ftMa.pressed)
                    name: "filter"; size: Theme.glyph(14)
                    ink: root.hasFilters ? "highlight"
                       : root.showFilters ? "textOnActive"
                       : ftMa.containsMouse ? "text" : "textSoft"
                }
                MouseArea { id: ftMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: root.showFilters = !root.showFilters }
            }

            // filter row
            component FilterSelect: SelectHead {
                id: fs
                property var options: []          // [{value, label}]
                property string value
                signal picked(string v)
                function labelFor(v) {
                    for (const o of options) if (o.value === v) return o.label
                    return v
                }
                label: labelFor(value)
                menu: contextMenu
                onClicked: {
                    const p = fs.mapToItem(null, 0, fs.height)
                    contextMenu.open(p.x, p.y, fs.options.map(o =>
                        ({ label: o.label, act: () => fs.picked(o.value) })), undefined, fs)
                }
            }
            Row {
                y: searchBarRect.rowH + 2
                anchors.left: parent.left
                anchors.leftMargin: Theme.inset("header", "left") + searchBarRect.cutL
                height: 26
                spacing: Theme.gap(10)
                visible: root.showFilters

                component FilterGroup: Row {
                    property alias label: fgLabel.text
                    default property alias content: fgSlot.data
                    spacing: Theme.gap(4)
                    anchors.verticalCenter: parent.verticalCenter
                    InkText { id: fgLabel; anchors.verticalCenter: parent.verticalCenter
                           ink: "textDim"
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                    Item { id: fgSlot; width: childrenRect.width; height: 22
                           anchors.verticalCenter: parent.verticalCenter }
                }
                FilterGroup { label: "Sort"
                    FilterSelect { value: root.searchSort; onPicked: (v) => root.searchSort = v
                        options: [ { value: "relevance", label: "Relevance" },
                                   { value: "date", label: "Upload date" },
                                   { value: "views", label: "View count" },
                                   { value: "rating", label: "Rating" } ] } }
                FilterGroup { label: "Type"
                    FilterSelect { value: root.searchType; onPicked: (v) => root.searchType = v
                        options: [ { value: "any", label: "Any" },
                                   { value: "video", label: "Video" },
                                   { value: "playlist", label: "Playlist" },
                                   { value: "channel", label: "Channel" },
                                   { value: "movie", label: "Movie" } ] } }
                FilterGroup { label: "Upload date"
                    FilterSelect { value: root.searchDate; onPicked: (v) => root.searchDate = v
                        options: [ { value: "any", label: "Any time" },
                                   { value: "hour", label: "Last hour" },
                                   { value: "today", label: "Today" },
                                   { value: "week", label: "This week" },
                                   { value: "month", label: "This month" },
                                   { value: "year", label: "This year" } ] } }
                FilterGroup { label: "Duration"
                    FilterSelect { value: root.searchDuration; onPicked: (v) => root.searchDuration = v
                        options: [ { value: "any", label: "Any" },
                                   { value: "short", label: "Under 4 min" },
                                   { value: "medium", label: "4-20 min" },
                                   { value: "long", label: "Over 20 min" } ] } }
                InkText {
                    visible: root.hasFilters
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Clear"
                    ink: fcMa.containsMouse ? "text" : "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    MouseArea { id: fcMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: { root.searchSort = "relevance"; root.searchType = "any"
                                             root.searchDate = "any"; root.searchDuration = "any" } }
                }
            }

            Surface {
                y: searchBarRect.yFor(height)
                anchors.left: searchBarRect.combined ? tabBar.right : parent.left
                anchors.right: filterToggle.left
                // the tabs beside it are not an edge: that stays air
                anchors.leftMargin: searchBarRect.combined ? Theme.gap(4)
                                                           : Theme.inset("header", "left") + searchBarRect.cutL
                anchors.rightMargin: Theme.gap(6)
                height: searchBarRect.fieldH
                radius: Theme.radiusMd
                role: "input"
                borderWidth: 1
                borderRole: searchInput.activeFocus ? "borderStrong" : "border"

                Icon {
                    id: searchIcon
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.inset("input", "left")
                    name: "search"; size: Theme.glyph(13); ink: "textFaint"
                }
                TextInput {
                    id: searchInput
                    anchors.fill: parent
                    // past the icon, which sits at the field's own inset
                    anchors.leftMargin: searchIcon.x + searchIcon.width + Theme.gap(6)
                    anchors.rightMargin: Theme.inset("input", "right")
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
                    clip: true
                    onAccepted: {
                        if (!text.length) return
                        searching = true
                        PlayerState.view = 2
                        // placeholder rows morph in place when results arrive
                        root.searchFlow = SkeletonModel.beginLoad(
                            searchResults, searchView.placeholderCount())
                        root.searchContinuation = ""
                        root.lastQuery = text
                        root.sourceContinuations = ({})
                        root.pendingPluginRows = []
                        sidecar.search(text, root.buildFilters())
                        // fan out to plugin sources in parallel (merged search)
                        for (let i = 0; i < root.pluginSources.length; i++)
                            sidecar.pluginSearch(root.pluginSources[i].id, text)
                    }
                    property bool searching: false
                    // The search box filters the library live. Synced on EVERY
                    // change (not just while on the Library view) — clearing
                    // the text from another view must clear the filter too.
                    onTextChanged: Library.filter = text
                    InkText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !searchInput.text.length && !searchInput.activeFocus
                        text: "search"
                        ink: "textFaint"
                        font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
                    }
                }
            }
        }

        // the tab bar's own row, empty while the tabs sit in the search row
        Item {
            id: tabsSlot
            x: root.shaped ? 0 : root.frL
            width: parent.width - (root.shaped ? 0 : root.frL + root.frR)
            height: searchBarRect.combined ? 0 : tabBar.height
            AppTabBar {
                id: tabBar
                backdrop: ground
                // the strip starts inside the cut; its row runs to the frame
                parent: searchBarRect.combined ? searchBarRect : tabsSlot
                ground: !searchBarRect.combined && !root.headTabs
                // In the search row the strip has no edge of its own, so the
                // row's inset places the first TAB: adding the strip's own on
                // top of it would inset the same visible edge twice.
                x: searchBarRect.combined
                   ? Theme.inset("header", "left") - Theme.inset("tabs", "left") + searchBarRect.cutL
                   : (root.shaped ? root.cutLOf(tabsSlot) : 0)
                // ...and the same holds top and bottom: the tabs themselves are
                // centred in the row, not the strip with its insets, whose
                // bottom matches the gap to the search row when on its own row
                y: searchBarRect.combined
                   ? searchBarRect.yFor(height - Theme.inset("tabs", "top") - Theme.inset("tabs", "bottom")) - Theme.inset("tabs", "top")
                   : 0
                width: searchBarRect.combined ? implicitWidth
                     : parent.width - (root.shaped ? root.cutLOf(tabsSlot) + root.cutROf(tabsSlot) : 0)
                hasSearchResults: searchResults.count > 0 || searchInput.searching
            }
        }

        // main area: active view; queue panel OVERLAYS it (panes behavior —
        // it floats over the content, never reflows it)
        Item {
            x: root.shaped ? 0 : root.frL
            width: parent.width - (root.shaped ? 0 : root.frL + root.frR)
            height: Math.max(0, parent.height - mainTitle.height - (Theme.borderTitle ? root.frT : 0) - searchBarRect.height - tabsSlot.height)

            // The surface the views sit on, between the header and the player.
            // Nothing by default, so the window shows through; a theme that
            // sets it gets a panel with an edge of its own, which a bevel needs.
            Surface {
                anchors.fill: parent
                role: "page"
                backdrop: ground
                visible: Theme.hasPage
                // Rounded like the window where the theme asks: a page over a
                // floating bar with nothing behind it ends in open space, and
                // square corners there read as cut off
                readonly property real pageTop: Theme.pageCorners === "all" ? root.cornerRadius : 0
                readonly property real pageBottom: Theme.pageCorners === "none" ? 0 : root.bottomCornerRadius
                topLeftRadius: pageTop; topRightRadius: pageTop
                bottomLeftRadius: pageBottom; bottomRightRadius: pageBottom
            }
            Item {
                id: pageShape
                visible: false
                anchors.fill: parent
                layer.enabled: root.pageFoot > 0
                Rectangle { anchors.fill: parent; color: "#ffffff"
                            topLeftRadius: root.pageHead; topRightRadius: root.pageHead
                            bottomLeftRadius: root.pageFoot; bottomRightRadius: root.pageFoot }
            }
            Item {
                id: viewArea
                // The views start inside what the shape cuts, while the page
                // they sit on runs to the frame: a surface stopping short of
                // the cut leaves a wedge of window beside it, which reads as a
                // second edge beside the border's.
                anchors.fill: parent
                anchors.leftMargin: root.shaped ? root.cutLOf(viewArea) : 0
                anchors.rightMargin: root.shaped ? root.cutROf(viewArea) : 0
                layer.enabled: root.pageFoot > 0
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: pageShape
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }

                // Visualizer (view 4) — also the default backdrop
                Item {
                    id: vizSlot
                    anchors.fill: parent

                    // The `visualizer` slot: a bound plugin draws in melo's window at melo's
                    // size, replacing the visualiser that is also the default backdrop. The
                    // occupant is built in the plugin's engine and reparented here, so no anchors
                    // cross the seam; the gate sets its geometry to fill, as a backdrop does.
                    Item {
                        id: vizPluginGate
                        objectName: "meloSlot:visualizer"
                        // Same rule as melo's visualiser: this item covers the whole view area, so
                        // without the view check a plugin would paint behind library, search and home.
                        // The mini popup stays melo's: it reparents the shared projectM between slots.
                        visible: root.vizSlotFilled
                                 && PlayerState.view === 4 && !root.miniPlayer
                        anchors.fill: parent
                        function fit() {
                            for (let i = 0; i < children.length; ++i) {
                                children[i].x = 0
                                children[i].y = 0
                                children[i].width = width
                                children[i].height = height
                            }
                        }
                        onWidthChanged: fit()
                        onHeightChanged: fit()
                        onChildrenChanged: fit()
                    }
                    // graceful fallback: machine can't do OpenGL 3.3 (Windows
                    // VM/RDP/no GPU drivers) — UI runs on D3D11/WARP, projectM off
                    InkText {
                        anchors.centerIn: parent
                        visible: !MELO_HAS_GL && PlayerState.view === 4 && !root.miniPlayer
                        text: "Visualizer unavailable — this system has no OpenGL (GPU) support"
                        ink: "textFaint"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                    }

                }
                // ONE projectM instance shared by the full view and the mini
                // popup (reparented; nextPreset state travels with it — two
                // instances showed different presets). A Loader, so a
                // machine without OpenGL 3.3 never builds it.
                Loader {
                    active: MELO_HAS_GL
                    sourceComponent: Visualizer {
                        id: viz
                        parent: root.miniVisWanted && root.miniQueueShown ? miniVisSlot : vizSlot
                        anchors.fill: parent
                        // inset inside the rounded card so its square corners
                        // clear the card's rounded corners (max(1) keeps a
                        // 1px top gap in the mini slot)
                        anchors.margins: parent === miniVisSlot
                            ? Math.max(1, Theme.windowRadius) : 0
                        // ...unless a plugin occupies the slot. Bound means
                        // INSTEAD OF, not on top of — two visualisers drawing
                        // the same audio in the same rectangle is the failure
                        // mode a slot exists to avoid.
                        visible: !root.vizSlotFilled
                                 && ((PlayerState.view === 4 && !root.miniPlayer)
                                     || (root.miniVisWanted && root.miniQueueShown))
                        // visualizerBg "transparent": glass shows through
                        opacity: Theme.ts.visualizerBg === "transparent" ? Theme.opacityScale : 1
                        // click-to-preset: left = next (or a RANDOM preset with
                        // visRandomClick on), right = back through the history
                        // of what actually played — every switch source (click,
                        // auto-cycle, search) records the preset it left
                        property bool randomClick: Settings.uiGet("visRandomClick", false) === true
                        Connections {
                            target: Settings
                            function onChanged() {
                                viz.randomClick = Settings.uiGet("visRandomClick", false) === true
                            }
                        }
                        property var presetHistory: []
                        property string lastPresetSeen: ""
                        property bool navBack: false
                        onCurrentPresetChanged: {
                            if (navBack) { navBack = false; lastPresetSeen = currentPreset; return }
                            if (lastPresetSeen.length) {
                                presetHistory.push(lastPresetSeen)
                                if (presetHistory.length > 128) presetHistory.shift()
                            }
                            lastPresetSeen = currentPreset
                        }
                        function randomPreset() {
                            const n = presetNames.length
                            if (n < 2) return
                            let i = Math.floor(Math.random() * n)
                            if (presetNames[i] === currentPreset) i = (i + 1) % n
                            playPresetAt(i)
                        }
                        function backPreset() {
                            if (!presetHistory.length) { prevPreset(); return }
                            const name = presetHistory.pop()
                            const i = presetNames.indexOf(name)
                            if (i < 0) { prevPreset(); return }
                            navBack = true
                            playPresetAt(i)
                        }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: (m) => m.button === Qt.RightButton ? viz.backPreset()
                                         : (viz.randomClick ? viz.randomPreset() : viz.nextPreset())
                        }
                        // preset name flashes on every switch (click, auto-
                        // cycle, search) — milkdrop convention
                        Surface {
                            id: presetToast
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: Theme.gap(14)
                            width: presetToastText.implicitWidth + Theme.inset("toast", "left")
                                   + Theme.inset("toast", "right")
                            // 16 is the row the words sit in
                            height: Theme.inset("toast", "top") + 16 + Theme.inset("toast", "bottom")
                            radius: Theme.radiusMd
                            role: "toast"
                            opacity: 0
                            visible: opacity > 0
                            z: 9
                            Behavior on opacity { NumberAnimation { duration: 250 } }
                            InkText {
                                id: presetToastText
                                x: Theme.inset("toast", "left")
                                y: Theme.inset("toast", "top") + (16 - implicitHeight) / 2
                                text: viz.currentPreset
                                ink: "text"
                                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                            }
                            Connections {
                                target: viz
                                function onCurrentPresetChanged() {
                                    if (!viz.currentPreset.length) return
                                    presetToast.opacity = 1
                                    presetToastTimer.restart()
                                }
                            }
                            Timer {
                                id: presetToastTimer
                                interval: 2600
                                onTriggered: presetToast.opacity = 0
                            }
                        }
                        // gear + config popover
                        // INSIDE the viz item so it travels between the full
                        // view and the mini popup with the reparenting
                        Item {
                            anchors.fill: parent
                            z: 10
                            visible: viz.visible
                            onVisibleChanged: if (!visible) vizConfigPanel.visible = false
                            HoverHandler { id: vizHover }
                            Rectangle {
                                id: vizGearBtn
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: Theme.gap(10)
                                width: Theme.ctl(30); height: Theme.ctl(30); radius: Theme.pill(15)
                                color: vizGearMa.containsMouse ? Theme.hover : Qt.rgba(0, 0, 0, 0.35)
                                opacity: vizHover.hovered || vizConfigPanel.visible ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                Icon { anchors.centerIn: parent; name: "settings"; size: Theme.glyph(16)
                                       ink: "text" }
                                MouseArea {
                                    id: vizGearMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: vizConfigPanel.visible ? vizConfigPanel.visible = false
                                                                      : vizConfigPanel.open(vizGearBtn)
                                }
                            }
                            // a window (it needs a surface to be blurred
                            // behind), so it places itself off the gear rather
                            // than anchoring inside the visualiser
                            VisConfigPanel {
                                id: vizConfigPanel
                                viz: viz
                            }
                        }
                        // live projectM settings from ui.* (applied render-thread)
                        function applyVisSettings() {
                            viz.setBeatSensitivity(Number(Settings.uiGet("visBeatSensitivity", 1)))
                            viz.setPresetDuration(Number(Settings.uiGet("visPresetDuration", 30)))
                            viz.setShuffle(Settings.uiGet("visShuffle", true) !== false)
                            viz.setPresetLocked(Settings.uiGet("visPresetLocked", false) === true)
                        }
                        // Paused music is a still frame; there is nothing to
                        // animate and no reason to hold the GPU at 60fps.
                        property bool playingHint: PlayerState.isPlaying
                        onPlayingHintChanged: viz.setPlaying(playingHint)
                        Component.onCompleted: { applyVisSettings(); viz.setPlaying(playingHint) }
                        Connections { target: Settings; function onChanged() { viz.applyVisSettings() } }
                    }
                }

                // Hidden pages are unanchored so a window drag does not relay out all five;
                // `visible` applies synchronously, so a page switch is laid out in the frame
                // that shows it. Measured -33% pre-sync on a resize.
                SearchView {
                    id: searchView
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 2
                    model: searchResults
                    // YouTube is always present; plugin sources join the filter row
                    sources: [{ id: "youtube", name: "YouTube" }].concat(root.pluginSources)
                    contextMenu: contextMenu
                    trackMenu: (t, sx, sy) => root.openTrackMenu(t, sx, sy)
                    layout: root.trackLayout
                    loadingMore: root.searchFetchingMore
                    searching: searchInput.searching
                    onChangeLayout: (mode) => root.changeTrackLayout(mode)
                    onNeedMore: root.fetchMoreResults()
                    onOpenPlaylist: (pid, title) => root.openPlaylistView(pid, title)
                }

                LibraryView {
                    id: libView
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 1
                    contextMenu: contextMenu
                    trackMenu: (t, sx, sy) => root.openTrackMenu(t, sx, sy)
                    prompt: promptDialog
                    layout: root.trackLayout
                    onChangeLayout: (mode) => root.changeTrackLayout(mode)
                    onOpenPlaylist: (pid, title, tracks) => root.openPlaylistView(pid, title, tracks)
                    onImportFiles: root.pickImport()
                }

                HomeView {
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 0
                    contextMenu: contextMenu
                    trackMenu: (t, sx, sy) => root.openTrackMenu(t, sx, sy)
                    layout: root.trackLayout
                    onChangeLayout: (mode) => root.changeTrackLayout(mode)
                    onOpenPlaylist: (playlistId, title) => root.openPlaylistView(playlistId, title)
                }

                Loader {
                    id: npLoader
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 5
                    sourceComponent: NowPlaying { anchors.fill: parent
                                                 visible: PlayerState.view === 5 }
                }

                PlaylistView {
                    id: playlistView
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 3
                    contextMenu: contextMenu
                    trackMenu: (t, sx, sy) => root.openTrackMenu(t, sx, sy)
                    layout: root.trackLayout
                    onChangeLayout: (mode) => root.changeTrackLayout(mode)
                    onBack: PlayerState.view = root.playlistReturnView
                }
            }

            QueuePanel {
                id: queuePanel
                // Bound means INSTEAD OF: melo's queue and a plugin's cannot
                // both have the right-hand strip.
                visible: !root.queueSlotFilled
                         && PlayerState.showPanel && PlayerState.hasTrack
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                z: 10
                contextMenu: contextMenu
            }

            // The `queuePanel` slot. A panel has a width of its own: the occupant's
            // implicitWidth is honoured and the content area gives way, else melo's 320.
            // Height is always melo's full strip.
            Item {
                id: queuePluginGate
                objectName: "meloSlot:queuePanel"
                visible: root.queueSlotFilled
                         && PlayerState.showPanel && PlayerState.hasTrack
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                z: 10
                width: {
                    const kid = children.length > 0 ? children[0] : null
                    return (kid && kid.implicitWidth > 0) ? kid.implicitWidth
                                                          : queuePanel.width
                }
                // The occupant is created in the PLUGIN's engine and reparented
                // here, so it cannot anchor across the seam — the gate sets its
                // geometry. Width is not set here: the gate takes its width FROM
                // the child, and writing it back would be a binding loop.
                function fit() {
                    for (let i = 0; i < children.length; ++i) {
                        children[i].x = 0
                        children[i].y = 0
                        children[i].height = height
                    }
                }
                onHeightChanged: fit()
                onChildrenChanged: fit()
            }
        }

    }

    // What the shape eats into each edge, per band of the window: the title
    // bar's two ends, the body between the header and the bar, and the bar
    // itself. A cut deeper than the frame would otherwise take whatever is
    // drawn there — a caption button, the end of the seek bar.
    property real cutTitleL: 0
    property real cutTitleR: 0
    property real cutBodyL: 0
    property real cutBodyR: 0
    property real cutBarL: 0
    property real cutBarR: 0
    // A surface fills a shaped window and the shape cuts it; what sits on the
    // surface starts inside the deeper of the frame and the cut. Inset by the
    // frame alone, a surface stops short wherever the shape cuts deeper, and
    // the window shows through between it and the border.
    readonly property bool shaped: mainShape.active && mainShape.hasShape
    // What the shape eats over one band of the window. Asked per row rather
    // than per window: inset by the deepest cut anywhere, a row the cut does
    // not reach stands off the edge for no reason. `generation` is read so the
    // binding asks again when the shape or the window changes.
    function cutL(y0, y1) {
        const dep = mainShape.generation
        return shaped ? Math.max(frL, mainShape.intrusion("left", y0, y1)) : frL
    }
    function cutR(y0, y1) {
        const dep = mainShape.generation
        return shaped ? Math.max(frR, mainShape.intrusion("right", y0, y1)) : frR
    }
    // ...for one item's own band, in window coordinates
    function cutLOf(item) {
        const dep = mainShape.generation + item.y + item.height + root.height
        const at = item.mapToItem(null, 0, 0).y
        return cutL(at, at + item.height)
    }
    function cutROf(item) {
        const dep = mainShape.generation + item.y + item.height + root.height
        const at = item.mapToItem(null, 0, 0).y
        return cutR(at, at + item.height)
    }
    function cutT(x0, x1) {
        const dep = mainShape.generation
        return shaped ? Math.max(frT, mainShape.intrusion("top", x0, x1)) : frT
    }
    function cutB(x0, x1) {
        const dep = mainShape.generation
        return shaped ? Math.max(frB, mainShape.intrusion("bottom", x0, x1)) : frB
    }
    function readCuts() {
        const titleH = mainTitle.height
        const barTop = height - playerBar.settledHeight
        cutTitleL = shaped ? Math.max(frL, mainShape.intrusion("left", 0, titleH)) : frL
        cutTitleR = shaped ? Math.max(frR, mainShape.intrusion("right", 0, titleH)) : frR
        cutBodyL = shaped ? Math.max(frL, mainShape.intrusion("left", titleH, barTop)) : frL
        cutBodyR = shaped ? Math.max(frR, mainShape.intrusion("right", titleH, barTop)) : frR
        cutBarL = shaped ? Math.max(frL, mainShape.intrusion("left", barTop, height)) : frL
        cutBarR = shaped ? Math.max(frR, mainShape.intrusion("right", barTop, height)) : frR
    }
    onShapedChanged: readCuts()
    Connections { target: mainShape; function onShapeApplied() { root.readCuts() } }
    // The window's shape, over everything including popups: outside it is
    // cleared, and takes no clicks
    // the shape is written on every resize: what it eats is read back there
    Connections { target: mainShape
                  function onShapeApplied() { root.applyBlur(); root.readCuts() } }
    // the mini window's own: its bar is the whole window, so one pair does it
    property real miniCutL: 0
    property real miniCutR: 0
    function readMiniCuts() {
        const on = miniShape.active && miniShape.hasShape
        miniCutL = on ? Math.max(0, miniShape.intrusion("left", 0, miniWin.height)) : 0
        miniCutR = on ? Math.max(0, miniShape.intrusion("right", 0, miniWin.height)) : 0

    }
    Connections { target: miniShape; function onShapeApplied() { root.readMiniCuts() } }
    WindowShape {
        id: mainShape
        parent: root.contentItem
        anchors.fill: parent
        z: 10000000
        spec: Theme.shapeFor(root.topCornerRadius, root.bottomCornerRadius)
        // a maximised window is the screen's shape
        active: spec !== null && root.visibility !== Window.Maximized && root.visibility !== Window.FullScreen
    }
    // Window frame and border are top-level overlays above the bar (z:10); inside
    // the background layer the bar occluded the border's bottom. A bar on the
    // surface backing is the window's own edge, so it keeps the one frame.
    readonly property bool borderInParts: Theme.windowBorderFit === "parts" && playerBar.shownBacking !== "surface"
    WindowBorder {   // round the whole window, or the part above a bar that stands apart
        x: 0; y: 0
        width: parent.width
        height: root.borderInParts ? root.upperH : parent.height
        borderLeft: root.frL; borderRight: root.frR
        borderTop: root.frT; borderBottom: root.frB
        // the title in the border: the frame goes round it, the band starts under it
        titleHeight: Theme.borderTitle && !root.frameOff ? mainTitle.height : 0
        // round the whole window, its outer edge is the window's shape
        shape: !root.borderInParts && mainShape.active ? mainShape : null
        titleRim: root.frameOff ? 0 : Theme.borderTitleRim
        titleFade: Theme.borderTitleFade
        radiusTL: root.topCornerRadius
        radiusTR: root.topCornerRadius
        radiusBL: root.borderInParts ? (Theme.pageCorners === "none" ? 0 : root.bottomCornerRadius) : root.bottomCornerRadius
        radiusBR: root.borderInParts ? (Theme.pageCorners === "none" ? 0 : root.bottomCornerRadius) : root.bottomCornerRadius
        backdrop: ground
        visible: root.frameDrawn && root.fullBarVisible
        opacity: root.fullBaseOpacity
        z: 930
    }
    WindowBorder {   // round the bar that stands apart: its card, or its own place
        readonly property bool card: root.barCard
        x: card ? playerBar.x + playerBar.inset - root.frL : playerBar.x - root.frL
        y: card ? playerBar.y + playerBar.cardTop - root.frT : playerBar.y - root.frT
        width: (card ? playerBar.width - 2 * playerBar.inset : playerBar.width) + root.frL + root.frR
        height: (card ? playerBar.height - playerBar.cardTop - playerBar.cardBottom : playerBar.height) + root.frT + root.frB
        borderLeft: root.frL; borderTop: root.frT; borderRight: root.frR; borderBottom: root.frB
        // concentric with the card's corners; its own place is square above
        // and the window's below
        radiusTL: card ? Theme.radiusLg + Math.max(root.frL, root.frT) : 0
        radiusTR: card ? Theme.radiusLg + Math.max(root.frR, root.frT) : 0
        radiusBL: card ? Theme.radiusLg + Math.max(root.frL, root.frB) : root.bottomCornerRadius
        radiusBR: card ? Theme.radiusLg + Math.max(root.frR, root.frB) : root.bottomCornerRadius
        backdrop: ground
        visible: root.frameDrawn && root.borderInParts && root.fullBarVisible && height > 0
        opacity: root.fullBaseOpacity
        z: 930
    }

    // ---------- overlays ----------
    ContextMenu { id: contextMenu }

    // Truncated-text tooltip (Tip singleton impl). A window of its own, like
    // the menus: blur is per surface, so an in-window rectangle could never
    // take the glass they get — and this way it is not clipped by the window
    // edge either.
    Window {
        id: textTipPopup
        flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
        color: "transparent"
        visible: false
        width: Math.min(tipText.implicitWidth + Theme.inset("tooltip", "left")
                        + Theme.inset("tooltip", "right"), 360)
        height: tipText.height + Theme.inset("tooltip", "top") + Theme.inset("tooltip", "bottom")
        property var owner: null

        // same rule as the menus: the region is built from the size at apply
        // time, and the size follows the text
        function applyGlass() {
            if (!textTipPopup.visible) return
            WindowCtl.setBlurRadius(Theme.radiusMd)
            WindowCtl.setBlurBehind(textTipPopup, Theme.menuBlur)
            WindowCtl.setBackgroundContrast(textTipPopup, Theme.menuBlur, Theme.glassContrast, Theme.glassSaturation)
        }
        onVisibleChanged: applyGlass()
        onWidthChanged: applyGlass()
        onHeightChanged: applyGlass()

        function showFor(text, item) {
            owner = item
            tipText.text = text
            const host = root
            // window coords, then the host's position (0,0 on Wayland, real on X11)
            transientParent = host
            const p = item.mapToItem(host.contentItem, 0, item.height + 6)
            x = host.x + Math.max(6, Math.min(p.x, host.width - width - 6))
            y = host.y + Math.min(p.y, host.height - height - 6)
            visible = true
        }
        function hideFor(item) { if (owner === item) { visible = false; owner = null } }
        Component.onCompleted: Tip.impl = textTipPopup

        Surface {
            anchors.fill: parent
            radius: Theme.radiusMd
            role: "tooltip"
            borderWidth: 1
            borderRole: "border"
            InkText {
                id: tipText
                x: Theme.inset("tooltip", "left"); y: Theme.inset("tooltip", "top")
                width: Math.min(implicitWidth, 360 - Theme.inset("tooltip", "left")
                                              - Theme.inset("tooltip", "right"))
                wrapMode: Text.Wrap
                ink: "text"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
        }
    }
    PromptDialog { id: promptDialog }
    OnboardingWindow { id: onboarding; transientParent: root }

    // Asked once, on a display where it matters. The fix costs a coarser
    // resize step, so it is not turned on for anyone who would not see the
    // problem: a whole scale factor has a grain of 1 and nothing to fix.
    Timer {
        // Not before the settings are there. `gridSnapAsked` lives in them and
        // is false until the sidecar hands them over; a start slow enough to
        // still be waiting at 2500 ms asked a question that had been answered
        // and turned off for good.
        running: Settings.loaded; interval: 2500
        onTriggered: {
            if (root.gridSnap) return
            if (Settings.uiGet("gridSnapAsked", false) === true) return
            if (typeof WindowCtl === "undefined") return
            const d = WindowCtl.dprOf(root)
            if (!(d > 0) || root.snapGrain(d) <= 1) return
            promptDialog.askDialog(
                "This display is set to a fractional scale (" + Math.round(d * 100)
                + "%), which can make edges and text shimmer while melo is being resized.\n\n"
                + "melo can hold its window to sizes that land on whole screen "
                + "pixels, at the cost of slightly coarser resizing.\n\n"
                + "You can change this later in Settings.",
                "Turn on", "Not now", "Don't ask again",
                (ok, dontAsk) => {
                    if (ok) { Settings.uiSet("gridSnap", true); root.readGridSnap(); root.snapSize() }
                    if (ok || dontAsk) Settings.uiSet("gridSnapAsked", true)
                })
        }
    }

    // The sidecar reports an extraction failure that a newer yt-dlp usually
    // fixes. Switching update channel is the user's call, so ask rather than
    // change it for them; asked at most once per session.
    Connections {
        target: sidecar
        function onYtdlpStale(message) {
            promptDialog.confirmDialog(
                "Playback failed in a way a newer yt-dlp usually fixes.\n\n"
                + "Switch the yt-dlp channel from Stable to Nightly?",
                (ok) => {
                    if (!ok) return
                    sidecar.rpc("ytdlp/setChannel", { channel: "nightly" }, () => Settings.refresh())
                })
        }
    }
    PlaylistFlyout {
        id: playlistFlyout
        prompt: promptDialog
        // the menu it hangs off goes with it
        onVisibleChanged: if (!visible) contextMenu.close()
    }
    // and it goes when the menu does
    Connections {
        target: contextMenu
        function onSubClosed() { playlistFlyout.close() }
    }
    // Built when first opened: these two windows were half the QML JS heap, which
    // every GC walks, and melo collected several times a second while idle, each
    // collection stalling the GUI thread for a frame.
    // `visible` on a Loader's absent item is undefined (falsy), so callers that
    // only ask whether it is showing never build it.
    Loader {
        id: settingsLoader
        active: false
        sourceComponent: SettingsWindow {
            objectName: "settingsWin"
            onImportPaths: (paths) => root.importAndEdit(paths)
            mainAreaRatio: (root.lastFullWidth * root.lastFullHeight) / 2073600
        }
    }
    function settingsWindow() { settingsLoader.active = true; return settingsLoader.item }
    Loader {
        id: eqLoader
        active: false
        sourceComponent: EqWindow { objectName: "eqWin" }
    }
    function eqWindow() { eqLoader.active = true; return eqLoader.item }
    MetadataEditor { id: metadataEditor }

    // A library edit reaches the track that is playing: the bar, Now playing
    // and MPRIS take the new name without waiting for the next track
    Connections {
        target: Library
        function onCountsChanged() {
            const t = PlayerState.currentTrack
            if (PlayerState.hasTrack && t && t.id) Player.refreshTrack(Library.playable(t.id))
        }
    }

    // Imported files are named by their filename, so each one opens in the
    // metadata editor as it lands, one after another as each is closed.
    property var importQueue: []
    function importAndEdit(paths) {
        sidecar.rpc("library/importFiles", { paths: paths }, (res) => {
            const ts = res && res.ok && res.result && res.result.tracks ? res.result.tracks : []
            root.importQueue = root.importQueue.concat(ts.map((t) => t.id))
            if (!metadataEditor.visible) root.editNextImport()
        })
    }
    function editNextImport() {
        if (!root.importQueue.length) return
        const q = root.importQueue.slice()
        const id = q.shift()
        root.importQueue = q
        metadataEditor.openFor(id)
    }
    Connections {
        target: metadataEditor
        function onVisibleChanged() { if (!metadataEditor.visible) Qt.callLater(root.editNextImport) }
    }
    function pickImport() {
        Portal.openFile("library-import", "Import audio files", "Audio",
                        ["*.mp3", "*.opus", "*.ogg", "*.webm", "*.m4a", "*.flac", "*.wav"], true)
    }
    Connections {
        target: Portal
        function onPicked(tag, paths) { if (tag === "library-import" && paths.length) root.importAndEdit(paths) }
    }

    // Shared by search rows and library rows. No "Play" entry (clicking the row plays).
    function openTrackMenu(t, sx, sy, host) {
        contextMenu.open(sx, sy, trackActs(t), host)
    }
    function trackActs(t) {
        const inLibrary = Library.isInLibrary(t.id)
        const isDownloaded = Library.isDownloaded(t.id)
        const ld = Settings.uiGet("libraryDefault", "both")
        const pd = Settings.uiGet("playlistDefault", "both")
        const acts = []

        // The playing track cannot queue after itself, so it gets neither entry.
        const playing = PlayerState.hasTrack
                        && PlayerState.currentTrack && PlayerState.currentTrack.id === t.id
        if (PlayerState.hasTrack && !playing) {
            acts.push({ label: "Add to next up", act: () => Player.playNext([t]) })
            acts.push({ label: "Add to Queue", act: () => Player.addToQueue([t]) })
        }
        if (!t.id.startsWith("local-")) {
            acts.push({ label: "Start Song Radio", act: () => Player.startRadio(t.id) })
            acts.push({ label: "Copy link", act: () => WindowCtl.copyToClipboard(
                            "https://www.youtube.com/watch?v=" + t.id) })
        }

        // `sub` keeps the menu standing and hands the row's right edge to the
        // panel, which is what a submenu is. The panel goes in the window the
        // menu is in: always naming the main window put it far off the mini
        // player's menu.
        if (pd === "both" || pd === "add" || isDownloaded)
            acts.push({ label: "Add to Playlist", sub: true,
                        act: (gx, gy) => playlistFlyout.openAt(contextMenu.hostWin || root, gx, gy, t, false) })
        if ((pd === "both" || pd === "download") && !isDownloaded)
            acts.push({ label: "Add to Playlist & Download", sub: true,
                        act: (gx, gy) => playlistFlyout.openAt(contextMenu.hostWin || root, gx, gy, t, true) })

        if (inLibrary) {
            if (!isDownloaded)
                acts.push({ label: "Download", act: () => Library.download(t.id) })
            acts.push({ label: "Edit Metadata", act: () => metadataEditor.openFor(t.id) })
            acts.push({ label: "Remove from Library", act: () => {
                if (isDownloaded)
                    promptDialog.confirmDialog("Delete the downloaded audio file too?",
                        (del) => Library.removeTrack(t.id, del === true))
                else
                    Library.removeTrack(t.id, false)
            } })
        } else {
            if (ld === "both" || ld === "add")
                acts.push({ label: "Add to Library", act: () => Library.addTrack(t, false) })
            if (ld === "both" || ld === "download")
                acts.push({ label: "Add to Library & Download", act: () => Library.addTrack(t, true) })
        }
        return acts
    }

    // The player bar's own menu: the playing track's entries, then the bar's.
    // Through CommandMap, as the bar's buttons go, so a plugin's intercepts hold.
    function openBarMenu(sx, sy, host) {
        const acts = PlayerState.hasTrack && PlayerState.currentTrack
                   ? trackActs(PlayerState.currentTrack) : []
        const slot = root.miniPlayer ? "barMini" : root.barView === 5 ? "barNp" : "barMain"
        acts.push({ label: "Keep melo above", check: root.alwaysOnTop, rule: acts.length > 0,
                    act: () => CommandMap.invoke("togglePin") })
        acts.push({ label: root.miniPlayer ? "Switch to full player" : "Switch to mini player",
                    act: () => CommandMap.invoke("toggleCompact") })
        // the arranger stands on the full window's bar, the mini slot included
        acts.push({ label: "Edit layout", act: () => {
            if (root.miniPlayer) root.toggleMini()
            root.startArrange(slot)
        } })
        contextMenu.open(sx, sy, acts, host)
    }

    // A press anywhere outside the search field drops its focus. Unaccepted
    // presses fall through to whatever is underneath, so this steals nothing.
    // (Also covers window re-activation handing focus straight back to the
    // TextInput.)
    MouseArea {
        anchors.fill: parent
        z: 940   // under the resize edges (950), over the content
        enabled: searchInput.activeFocus
        acceptedButtons: Qt.AllButtons
        onPressed: (m) => {
            const p = mapToItem(searchBarRect, m.x, m.y)
            if (!searchBarRect.contains(Qt.point(p.x, p.y)))
                searchInput.focus = false
            m.accepted = false
        }
    }

    // A popup rather than a band across the top, so a stream failure also
    // shows in the compact window.
    ErrorSurface {
        id: errorSurface
        // The sidecar being down is a STATE and must not auto-dismiss into a
        // window that then looks like it is working.
        state_: sidecar.ready ? "" : "melo's backend is not running"
        onActionTriggered: (kind) => {
            // Both actions are the one thing that fixes the case they appear
            // for: the cookie source lives in Settings, and a transient
            // network failure wants the same track asked for again.
            PlayerState.error = ""
            if (kind === "signin") root.settingsWindow().open()
            else if (kind === "retry" && PlayerState.hasTrack)
                Player.playTrackData(PlayerState.trackInfo)
        }
    }

    Rectangle {   // lite build on system GStreamer with pieces missing
        id: gstBanner
        property bool dismissed: false
        visible: MELO_MISSING_GST.length > 0 && !dismissed && !root.miniPlayer
        anchors.top: parent.top
        anchors.topMargin: Theme.gap(70)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(gstText.implicitWidth + 32, parent.width - 40)
        height: gstText.height + 16
        radius: Theme.radiusMd
        color: "#5c1f1f"
        border.color: Theme.accent
        z: 900
        InkText { id: gstText; anchors.centerIn: parent
               width: gstBanner.width - 24
               wrapMode: Text.Wrap
               horizontalAlignment: Text.AlignHCenter
               text: "GStreamer elements missing: " + MELO_MISSING_GST
                     + " — " + MELO_GST_HINT
               ink: "text"; font { pixelSize: Theme.fs(12); family: Theme.fontFamily } }
        MouseArea { anchors.fill: parent; onClicked: gstBanner.dismissed = true }
    }

    Rectangle {   // lite build: one-time Node.js runtime download
        visible: NodeSetup.active || NodeSetup.error.length > 0
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        z: 991
        MouseArea { anchors.fill: parent }   // modal
        Surface {
            anchors.centerIn: parent
            width: Math.min(380, parent.width - 40)
            height: nodeCol.implicitHeight + 32
            radius: Theme.radiusLg
            role: "dialog"
            borderWidth: 1
            borderRole: "border"
            Column {
                id: nodeCol
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.gap(16)
                spacing: Theme.gap(12)

                InkText {
                    text: NodeSetup.error.length > 0 ? "Node.js download failed"
                                                     : "Downloading Node.js"
                    ink: "text"
                    font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
                }
                Surface {   // progress track
                    visible: NodeSetup.active
                    width: parent.width; height: 6; radius: 3
                    role: "hover"
                    Surface {
                        width: parent.width * NodeSetup.progress
                        height: parent.height; radius: 3
                        role: "accent"
                    }
                }
                InkText {
                    visible: NodeSetup.active && NodeSetup.totalMB > 0
                    text: NodeSetup.receivedMB + " / " + NodeSetup.totalMB + " MB"
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                InkText {
                    visible: NodeSetup.error.length > 0
                    width: parent.width
                    text: NodeSetup.error
                    wrapMode: Text.Wrap
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                PushButton {
                    visible: NodeSetup.error.length > 0
                    pad: 24; fontSize: 12
                    label: "Retry"; accent: true
                    onClicked: NodeSetup.download()
                }
            }
        }
    }

    // ---------- search plumbing ----------
    ListModel { id: searchResults }
    property string searchContinuation: ""
    property bool searchFetchingMore: false
    property var searchFlow: null
    // merged multi-source search: plugin sources are queried in parallel with
    // YouTube and their results appended (progressive merge). Filtering by
    // source is client-side in SearchView.
    property var pluginSources: []          // [{id, name}]
    property var sourceContinuations: ({})  // sourceId -> continuation token
    property string lastQuery: ""
    // plugin rows arriving WHILE the YouTube skeleton flow owns searchResults
    // must be staged: the flow's trim/set use model.count as their boundary,
    // so tail-appended plugin rows would be overwritten or deleted. Buffer
    // here and flush once searchFlow is null.
    property var pendingPluginRows: []
    function flushPendingPluginRows() {
        if (!pendingPluginRows.length) return
        const rows = pendingPluginRows
        pendingPluginRows = []
        for (let i = 0; i < rows.length; i++) searchResults.append(rows[i])
    }
    function refreshPluginSources() {
        // rpc() delivers { ok, result } — sources live under result
        sidecar.rpc("plugins/sources", {}, (r) => {
            root.pluginSources = (r && r.ok && r.result && r.result.sources) ? r.result.sources : []
        })
    }
    Connections {
        target: sidecar
        function onReadyChanged() { if (sidecar.ready) root.refreshPluginSources() }
        function onPluginsChanged(plugins) {
            root.refreshPluginSources()
            // ...and the gestures, because whether a plugin is loaded is half
            // of what a gesture binding resolves to. Nothing in Settings
            // changed, so the Settings.onChanged route never fires here.
            Qt.callLater(root.refreshShortcuts)
        }
        function onPluginSearchResults(sourceId, tracks, continuation, append) {
            root.sourceContinuations[sourceId] = continuation || ""
            const rows = []
            for (let i = 0; i < tracks.length; i++) {
                const r = tracks[i]
                rows.push({ placeholder: false, vid: r.id, title: r.title || "",
                            channel: r.channel || "", duration: r.duration || 0,
                            thumbnail: r.thumbnail || "", src: sourceId })
            }
            // buffer while the YouTube flow owns the model (see pendingPluginRows)
            if (root.searchFlow) root.pendingPluginRows = root.pendingPluginRows.concat(rows)
            else for (let j = 0; j < rows.length; j++) searchResults.append(rows[j])
        }
        function onPluginSearchFailed(sourceId) {
            root.sourceContinuations[sourceId] = ""   // stop paginating a dead source
        }
    }

    Connections {
        target: sidecar
        function onSearchResults(results, playlists, continuation, append) {
            root.searchContinuation = continuation || ""
            root.searchFetchingMore = false
            searchInput.searching = false
            const hasMore = root.searchContinuation.length > 0
            // playlist results ride the same list ahead of the tracks
            // and carry isPlaylist + videoCount
            if (playlists && playlists.length) {
                const plRows = playlists.map((p) => ({
                    id: p.playlistId, title: p.title, channel: p.channel || "",
                    duration: 0, thumbnail: p.thumbnail || "",
                    isPlaylist: true, videoCount: p.videoCount || 0 }))
                results = plRows.concat(results)
            }
            if (root.searchFlow) {
                // flow consumes placeholders across batches; asks for more
                // pages until they're all resolved (single trim at the end)
                const wantMore = SkeletonModel.acceptBatch(
                    searchResults, root.searchFlow, results, hasMore)
                if (wantMore) Qt.callLater(root.fetchMoreRaw)
                else { root.searchFlow = null; root.flushPendingPluginRows() }
            } else if (append) {
                for (let i = 0; i < results.length; i++)
                    searchResults.append(SkeletonModel.toRow(results[i]))
            } else {
                SkeletonModel.apply(searchResults, results)
            }
            if (!append && results.length > 0) PlayerState.view = 2
        }
        function onRpcFailed(what, message) {
            if (what !== "search") return
            searchInput.searching = false
            root.searchFetchingMore = false
            if (root.searchFlow) {   // resolve the flow empty: single trim
                SkeletonModel.acceptBatch(searchResults, root.searchFlow, [], false)
                root.searchFlow = null
                root.flushPendingPluginRows()   // plugin rows that already arrived survive a YT failure
            }
            PlayerState.error = message
        }
    }
    // flow follow-ups (placeholders still unresolved) skip tail creation
    function fetchMoreRaw() {
        if (searchContinuation.length && !searchFetchingMore) {
            searchFetchingMore = true
            sidecar.searchMore(searchContinuation)
        }
        // pull the next page from each plugin source that still has one
        for (const sid in sourceContinuations)
            if (sourceContinuations[sid])
                sidecar.pluginSearch(sid, lastQuery, sourceContinuations[sid])
    }
    function searchPaginationTail() {
        return SkeletonModel.paginationTail(trackLayout, searchView.width, searchResults.count, GridUi.growth)
    }
    function fetchMoreResults() {
        if (searchInput.searching || searchFlow) return
        if (!searchContinuation.length || searchFetchingMore) return
        // in-model tail: completes the grid's partial row + one full row
        searchFlow = SkeletonModel.beginAppend(searchResults, searchPaginationTail())
        fetchMoreRaw()
    }

    // playlist navigation: Back returns to the view the playlist was opened from
    property int playlistReturnView: 0
    function openPlaylistView(playlistId, title, initialTracks) {
        // a playlist opened from a playlist keeps the original origin
        if (PlayerState.view !== 3) root.playlistReturnView = PlayerState.view
        playlistView.open(playlistId, title, initialTracks || null)
        PlayerState.view = 3
    }

    // ---------- shortcuts (configurable) ----------
    // Bare-key shortcuts disable while typing: a matched QShortcut consumes the
    // key, so Space in a text field would toggle play. CommandMap owns them as
    // Qt::ApplicationShortcut so they fire in plugin windows, and watches
    // focusObjectChanged for typing in other melo windows. Do not clearKeys()
    // here: Settings.changed can fire from uiLock with QShortcut::activated on
    // the stack.
    property var sc: SC.merged(null)
    property var boundShortcutIds: []
    function refreshShortcuts() {
        sc = SC.merged(Settings.uiGet("shortcuts", null))
        const next = []
        for (const id in sc) {
            if (id === "bgPresetNext" || id === "bgPresetPrev")
                continue
            const seq = SC.toQt(sc[id])
            CommandMap.setKey(id, seq)
            if (seq) next.push(id)
        }
        for (let i = 0; i < boundShortcutIds.length; i++) {
            const id = boundShortcutIds[i]
            if (next.indexOf(id) < 0)
                CommandMap.setKey(id, "")
        }
        boundShortcutIds = next
        // Which plugin buttons the user took out. Restored before the bars
        // draw, and not filtered by what is currently offered: a hide for a
        // plugin that is off has to survive, or enabling it returns a button
        // the user removed.
        if (typeof BarButtons !== "undefined" && BarButtons)
            BarButtons.setHiddenKeys(Settings.uiGet("hiddenBarButtons", []))
        // SLOT BINDS, restored before this window has drawn anything. A slot
        // whose plugin is not there draws melo's own chrome and keeps the bind,
        // so this replays every stored one rather than filtering by what is
        // currently offered — see SlotMap.h.
        if (typeof SlotMap !== "undefined" && SlotMap) {
            const st = Settings.uiGet("slots", null)
            const ids = SlotMap.slotIds()
            for (let s = 0; s < ids.length; s++)
                SlotMap.setOccupant(ids[s], (st && st[ids[s]]) || "")
        }
        const g = Settings.uiGet("gestures", null)
        // A binding to an unloaded plugin falls back to melo's action but is kept,
        // so re-enabling the plugin restores it, as slots do.
        function bound(id, builtin) {
            const want = (g && g[id]) || ""
            if (!want) return builtin
            const dot = want.indexOf(".")
            if (dot < 0) return want                      // one of melo's own
            const owner = want.substring(0, dot)
            return (PluginUi && PluginUi.has(owner)) ? want : builtin
        }
        CommandMap.setGesture("playerBar.doubleClick",
            bound("playerBar.doubleClick", "toggleCompact"))
        CommandMap.setGesture("compact.escape",
            bound("compact.escape", "toggleCompact"))
        CommandMap.setGesture("titleBar.doubleClick",
            bound("titleBar.doubleClick", "toggleMaximize"))
        CommandMap.setCompactActive(root.miniPlayer)
        CommandMap.setTyping(root.typing)
    }
    Connections {   // shortcut edits in the settings window apply live
        target: Settings
        function onChanged() { Qt.callLater(root.refreshShortcuts) }
    }
    // Space activates a focused control and arrows move focus in Qt Quick, so
    // bare keys yield whenever the focused item (not the content item) takes text
    // (has cursorPosition) or tab focus, not only in text fields.
    readonly property bool typing: activeFocusItem !== null
                                   && activeFocusItem !== contentItem
                                   && (activeFocusItem.cursorPosition !== undefined
                                       || activeFocusItem.activeFocusOnTab === true)
    onMiniPlayerChanged: CommandMap.setCompactActive(root.miniPlayer)
    onTypingChanged: CommandMap.setTyping(root.typing)
    onActiveChanged: if (MELO_FOCUS_DEBUG)
        console.log("[focus-debug] root.active", active)
    onSysFocusedChanged: if (MELO_FOCUS_DEBUG)
        console.log("[focus-debug] sysFocused", sysFocused,
                    "mini", miniPlayer, "miniWin.active", miniWin.active)

    Connections {
        target: CommandMap
        function onInvoked(id) {
            switch (id) {
            case "toggleSearch":
                if (InterceptMap.offer("toggleSearch")) break
                root.showSearch = !root.showSearch
                if (root.showSearch) searchInput.forceActiveFocus()
                break
            case "playPause":
                Player.togglePlay()
                break
            case "rewind":
                Player.seek(Math.max(0, PlayerState.position - 5))
                break
            case "forward":
                Player.seek(PlayerState.position + 5)
                break
            case "nextTrack":
                Player.next()
                break
            case "prevTrack":
            case "prevTrackAlt":
                Player.previous()
                break
            case "addToLibrary": {
                if (!PlayerState.hasTrack) return
                const t = PlayerState.currentTrack
                if (!Library.isInLibrary(t.id))
                    Library.addTrack(t, Settings.uiGet("libraryDefault", "library") === "download")
                break
            }
            case "deleteTrack":
                // The same question the menu asks: a keystroke over a hovered
                // row must not delete the downloaded audio without the
                // confirmation the context menu gives.
                if (PlayerState.view === 1 && libView.hoveredTrackId.length) {
                    const delId = libView.hoveredTrackId
                    if (Library.isDownloaded(delId))
                        promptDialog.confirmDialog("Delete the downloaded audio file too?",
                            (del) => Library.removeTrack(delId, del === true))
                    else
                        Library.removeTrack(delId, false)
                }
                break
            // Chrome button bodies live in this switch so InterceptMap.offer() can hand
            // them to a plugin. toggleQueue branches: the compact bar clears miniVisWanted
            // and re-syncs the shared popup; the full bar toggles the panel.
            case "toggleQueue":
                if (InterceptMap.offer("toggleQueue")) break
                if (root.miniPlayer) {
                    root.miniVisWanted = false
                    PlayerState.showPanel = !PlayerState.showPanel
                    root.syncMiniQueue()
                } else {
                    PlayerState.showPanel = !PlayerState.showPanel
                }
                break
            case "toggleVisualizer":
                if (InterceptMap.offer("toggleVisualizer")) break
                PlayerState.showPanel = false
                root.miniVisWanted = !root.miniVisWanted
                root.syncMiniQueue()
                break
            case "toggleEq":
                if (InterceptMap.offer("toggleEq")) break
                eqLoader.item && eqLoader.item.visible ? eqLoader.item.visible = false
                                                       : root.eqWindow().open()
                break
            case "openSettings":
                if (InterceptMap.offer("openSettings")) break
                settingsLoader.item && settingsLoader.item.visible
                    ? settingsLoader.item.visible = false
                    : root.settingsWindow().open()
                break
            case "togglePin":
                if (InterceptMap.offer("togglePin")) break
                root.alwaysOnTop = !root.alwaysOnTop
                WindowCtl.setKeepAbove(root.alwaysOnTop)
                Settings.uiSet("alwaysOnTop", root.alwaysOnTop)
                break
            case "toggleCompact":
                if (!InterceptMap.offer("toggleCompact"))
                    root.toggleMini()
                break
            case "toggleMaximize":
                root.visibility === Window.Maximized ? root.showNormal() : root.showMaximized()
                break
            }
        }
    }
    // bgPresetNext/Prev are listed in shortcuts.js but not bound: they would
    // eat [ and ] as no-ops
    // Q toggles the queue panel
    Shortcut { enabled: !root.typing; sequence: "Q"
               onActivated: PlayerState.showPanel = !PlayerState.showPanel }

    // ---------- frameless window resize ----------
    // freeze tick UI + hold the hover fade the instant OUR handle is pressed
    function beginResizeHold() {
        sysDragging = true
        resizeFreeze = true          // carries the position freeze with it
        // The compact popup is a separate surface KWin glues under the bar, and
        // the compositor will not keep that glue honest through an interactive
        // resize — it lags the drag, smears, or lands off the bar. Close it for
        // the duration; reopening is one click.
        if (miniQueueShown) {
            PlayerState.showPanel = false
            miniVisWanted = false
            syncMiniQueue()
        }
    }
    // Separate from sysDragging, which hover also clears and which let the
    // freeze go mid-resize. Set by the two starts, cleared only by KWin's
    // interactive-resize-ended; everything that must hold still reads it.
    property bool resizeFreeze: false
    onResizeFreezeChanged: {
        // Freeze here, not in beginResizeHold: KWin-started resizes (border,
        // keyboard, Alt-drag) arrive at onInteractiveStarted, and the clock and seek
        // thumb, in melo and in plugins reading MeloUi.player.position, must hold
        // still for both.
        Player.setUiFrozen(resizeFreeze)
        Spectrum.setFrozen(resizeFreeze)
        if (PluginWindows) PluginWindows.setFrozen(resizeFreeze)
        resizeFreeze ? resizeFreezeSafety.restart() : resizeFreezeSafety.stop()
    }
    // Last resort only. The real releases are KWin's ended report and,
    // without KWin, the hover fallback above; this is a floor so a missed
    // signal cannot leave plugin windows permanently unable to redraw.
    Timer {
        id: resizeFreezeSafety
        interval: 30000
        onTriggered: root.resizeFreeze = false
    }
    // Left-edge bar resize: the overlay's host is repositioned only after the
    // resize (the KWin glue is silent during it) and Wayland cannot draw left of
    // the host, so the overlay width freezes for the drag and snaps after.
    property bool miniLeftResizeHold: false
    property int miniBarWFrozen: 0
    // KWin's finished report clears sysDragging; hover resuming clears it
    // too (non-KDE fallback) — release the tick freeze on either path
    onSysDraggingChanged: if (!sysDragging) {
        // Without KWin there is no "ENDED" REPORT, so the hover heuristic that
        // clears sysDragging is the only signal a drag finished. With KWin it
        // is a guess, and a wrong one mid-resize — which is why the freeze does
        // not take it there.
        if (!kwinSwap) resizeFreeze = false

        miniLeftResizeHold = false
    }
    // One grab area over the whole window, taking the ring inside the shape's
    // edge; rectangle strips sit as deep as the deepest cut beside them and
    // missed the edge wherever the shape is shallower.
    MouseArea {
        anchors.fill: parent
        z: 951
        visible: !root.miniPlayer && root.visibility !== Window.Maximized
        hoverEnabled: true
        containmentMask: mainShape.edgeRing
        acceptedButtons: Qt.LeftButton
        // which edges this point drags: the way the shape faces there
        function edgesAt(x, y) {
            const n = mainShape.edgeNormalAt(x, y)
            let e = 0
            if (n.x < -0.35) e |= Qt.LeftEdge
            else if (n.x > 0.35) e |= Qt.RightEdge
            if (n.y < -0.35) e |= Qt.TopEdge
            else if (n.y > 0.35) e |= Qt.BottomEdge
            return e
        }
        readonly property int hovered: containsMouse ? edgesAt(mouseX, mouseY) : 0
        cursorShape: {
            const e = hovered
            if (e === (Qt.LeftEdge | Qt.TopEdge) || e === (Qt.RightEdge | Qt.BottomEdge)) return Qt.SizeFDiagCursor
            if (e === (Qt.RightEdge | Qt.TopEdge) || e === (Qt.LeftEdge | Qt.BottomEdge)) return Qt.SizeBDiagCursor
            if (e === Qt.LeftEdge || e === Qt.RightEdge) return Qt.SizeHorCursor
            if (e === Qt.TopEdge || e === Qt.BottomEdge) return Qt.SizeVerCursor
            return Qt.ArrowCursor
        }
        onPressed: (m) => {
            const e = edgesAt(m.x, m.y)
            if (!e) { m.accepted = false; return }
            root.beginResizeHold()
            root.startSystemResize(e)
            m.accepted = true
        }
    }
}
