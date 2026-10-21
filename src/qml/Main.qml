import QtQuick
import QtQuick.Effects
import QtQuick.Window
import Qt5Compat.GraphicalEffects
import Melo 1.0
import "components"
import "components/skeletonmodel.js" as SkeletonModel
import "components/shortcuts.js" as SC
import "components/videowanted.js" as VideoWanted
import "components/layoutstate.js" as LayoutState
import "components/report.js" as Report
import "components/errortext.js" as ErrorText
import "components/playfail.js" as PlayFail
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
                    let tally = ({}), roles = [], total = 0
                    function walk(o) {
                        if (!o) return
                        let t = String(o).split("(")[0].split("_QML")[0].replace(/QQuick/, "")
                        tally[t] = (tally[t] || 0) + 1; total++
                        if (t === "Surface" && o.role !== undefined) roles.push(String(o.role))
                        let k = o.children
                        if (k) for (let j = 0; j < k.length; j++) walk(k[j])
                    }
                    walk(made[0])
                    let out = ""
                    for (let key in tally) if (tally[key] > 1 || key.indexOf("Fill") >= 0
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
    property string videoFit: "fill"
    function readVideoFit() { videoFit = String(Settings.uiGet("videoFit", "fill")) }
    Connections { target: Settings; function onChanged() { root.readGridSnap(); root.readVideoFit() } }
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
    // in mini mode main is the popup's host, sized by KWin to the bar
    function sizeStep() {
        if (!gridSnap || miniPlayer || typeof WindowCtl === "undefined") return 1
        if (visibility === Window.Maximized || visibility === Window.FullScreen) return 1
        const d = WindowCtl.dprOf(root)
        return d > 0 ? snapGrain(d) : 1
    }
    // X11: a resize of our own mid-drag fights the window manager's configures and
    // the edges wobble, so the snap waits for the drag to end. The size step is for
    // window managers that honour it; KWin 6 does not.
    function applySizeStep() { if (isX11 && typeof WindowCtl !== "undefined") WindowCtl.setSizeStep(root, sizeStep()) }
    onMiniPlayerChanged: { applySizeStep(); recordLayout() }
    function snapSize() {
        applySizeStep()
        const g = sizeStep()
        if (g <= 1 || (isX11 && sysDragging)) return
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
    minimumWidth: miniPlayer ? 0 : 384
    minimumHeight: miniPlayer ? 0 : 320
    visible: true
    color: "transparent"
    title: "melo"
    flags: Qt.Window | Qt.FramelessWindowHint

    // Mini bar height; the bar is furniture and scales with the UI. The mini
    // window is exactly its bar, one height per layout: a height that followed the
    // width snapped the window while the bar eased, showing clipped frames and
    // then desktop under it.
    // ...and never shorter than the rows and the player insets need. An unshaped
    // window moves the bar in by its frame, so the window takes the frame too.
    readonly property int barH: Math.max(Theme.bar(Theme.slotDoc("barMini:" + Theme.barMini, true).height || 77),
                                         Math.ceil(miniBar.settledHeight))
                                + (miniBar.framedWindow && !miniBar.shaped ? Math.round(frT + frB) : 0)
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
    readonly property bool isX11: Qt.platform.pluginName === "xcb"
    readonly property bool frameOff: (root.visibility === Window.Maximized || root.visibility === Window.FullScreen)
                                     && !Theme.borderMaximized
    readonly property real frL: frameOff ? 0 : Theme.borderLeft
    readonly property real frT: frameOff ? 0 : Theme.borderTop
    readonly property real frR: frameOff ? 0 : Theme.borderRight
    readonly property real frB: frameOff ? 0 : Theme.borderBottom
    // a frame with no title in it draws all its bands at the top, deeper than a thin top side
    // (10 px of bands over a 4 px top, say): what it frames starts below them
    readonly property real frTop: frameOff ? 0 : Theme.frameTopUntitled(frT)
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
    readonly property real contentTop: Theme.borderTitle ? 0 : frTop
    readonly property real barFoot: shaped ? 0 : barInB   // a shaped window's bar covers its own band
    readonly property real upperH: height - playerBar.settledHeight - barFoot - barRingTop
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
    onVisibilityChanged: {
        if (ready) applyBlur()
        applySizeStep()
        recordLayout()
        if (afterMaximized && visibility === Window.Maximized) runAfterMaximized()
    }
    property bool alwaysOnTop: false
    // the modes where melo sets the state itself and so can show it
    readonly property bool pinToggles: WindowCtl.pinMode === "kwin" || WindowCtl.pinMode === "flag"

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
    Binding { target: Theme; property: "maximized"
              value: !root.miniPlayer && (root.visibility === Window.Maximized || root.visibility === Window.FullScreen) }
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
    // Source = YouTube Music has only its own types
    readonly property bool musicSearch: Settings.homeSource === "ytmusic"
    onMusicSearchChanged: clearFilters()
    function clearFilters() {
        searchSort = "relevance"; searchType = "any"; searchDate = "any"; searchDuration = "any"
    }
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
    // Settings is read from the file before this loads (SettingsStore::loadLocal)
    // and applied in Component.onCompleted; with no file, the sidecar sends it later
    Connections {
        target: Settings
        function onLoadedChanged() { root.applySavedSettings() }
    }
    // KWin can place the window only once it has a frame on screen
    property bool firstFrameShown: false
    property var placeWhenFramed: null
    Connections {
        target: root
        enabled: !root.firstFrameShown
        function onFrameSwapped() {
            root.firstFrameShown = true
            if (root.placeWhenFramed) Qt.callLater(root.placeWhenFramed)
        }
    }
    // The layout is saved as it changes, never at quit: closing melo hides its windows.
    property var restorePlan: null
    // main stays hidden until the restored mini player's flip
    property bool restoringMini: false
    property bool layoutRestored: false
    property bool quitting: false
    readonly property bool layoutRecording: layoutRestored && !quitting
    onClosing: quitting = true
    Connections { target: Qt.application; function onAboutToQuit() { root.quitting = true } }
    // KWin can place the bar only once it has a frame
    property bool miniFramed: false
    property bool restoreWaitsForMini: false
    Connections {
        target: miniWin
        enabled: !root.miniFramed
        function onFrameSwapped() {
            root.miniFramed = true
            if (root.restoreWaitsForMini) { root.restoreWaitsForMini = false; Qt.callLater(root.restoreLayout) }
        }
    }
    Timer {   // a bar that never draws must not leave melo hidden
        running: root.restoringMini && !root.toggling && root.ready
        interval: 3000
        onTriggered: { root.miniFramed = true; root.restoreWaitsForMini = false; root.restoreLayout() }
    }
    function restoreLayout() {
        const p = restorePlan
        if (MELO_GEOM_DEBUG && p) console.warn("[layout] " + Date.now() + " restore " + JSON.stringify(p))
        if (p && p.mini && !miniPlayer && builtinMini) {
            if (!miniFramed) { restoreWaitsForMini = true; return }
            toggleMini()   // finishRestore after the flip
            return
        }
        finishRestore()
    }
    function finishRestore() {
        const p = restorePlan
        restorePlan = null
        if (restoringMini) { restoringMini = false; applyWindowOpacity() }
        if (p) {
            if (miniPlayer && p.popup === "queue") { miniVisWanted = false; PlayerState.showPanel = true; syncMiniQueue() }
            else if (miniPlayer && p.popup === "vis") { PlayerState.showPanel = false; miniVisWanted = true; syncMiniQueue() }
            for (const k of p.windows) winOf(k).reopen()
        }
        layoutRestored = true
        recordLayout()
        if (MELO_GEOM_DEBUG) console.warn("[layout] " + Date.now() + " restored mini " + miniPlayer + " popup " + miniQueueShown + " " + popupKind
                                          + " windows " + [queueWin, visWin, videoWin].filter(w => w.open).map(w => w.kind).join(","))
    }
    readonly property string popupWants: LayoutState.popupOf(miniVisWanted, PlayerState.showPanel, detached.queue === true)
    function rememberLayout(fields) {
        const l = Settings.uiGet("layout", null)
        const prev = l && typeof l === "object" ? l : ({})
        if (Object.keys(fields).every(k => prev[k] === fields[k])) return
        Settings.uiSet("layout", Object.assign({}, prev, fields))
    }
    function recordLayout() {
        const v = visibility === Window.Maximized ? "maximized" : visibility === Window.Windowed ? "windowed" : "other"
        const f = LayoutState.record({ recording: layoutRecording, toggling: toggling, miniPlayer: miniPlayer,
                                       popup: popupWants, visibility: v })
        if (f) rememberLayout(f)
    }
    onTogglingChanged: recordLayout()
    onPopupWantsChanged: recordLayout()
    Connections {
        target: WindowCtl
        function onMiniPosition(x, y) {
            if (root.layoutRecording && root.miniPlayer && !root.toggling) root.rememberLayout({ miniX: x, miniY: y })
        }
    }
    function screenRects() {
        return Array.prototype.map.call(Qt.application.screens, s => ({ x: s.virtualX, y: s.virtualY, width: s.width, height: s.height }))
    }
    // KWin maximises a restored main after moving it: content waits for that, up to 1.5 s
    property var afterMaximized: null
    function whenMaximized(f) { afterMaximized = f; maximizeWait.restart() }
    function runAfterMaximized() {
        const f = afterMaximized
        afterMaximized = null
        maximizeWait.stop()
        if (f) f()
    }
    Timer { id: maximizeWait; interval: 1500; onTriggered: root.runAfterMaximized() }
    // X11 without KWin: Qt knows both windows' places, so they are saved from there
    readonly property bool x11Places: isX11 && !WindowCtl.canPlaceWindows
    Timer {
        id: x11PlaceSave
        interval: 400
        onTriggered: {
            if (!root.layoutRecording || root.toggling) return
            if (root.miniPlayer) root.rememberLayout({ miniX: miniWin.x, miniY: miniWin.y })
            else if (root.visibility === Window.Windowed && (root.x !== root.savedX || root.y !== root.savedY)) {
                root.savedX = root.x
                root.savedY = root.y
                Settings.uiSet("windowX", root.x)
                Settings.uiSet("windowY", root.y)
            }
        }
    }
    onXChanged: if (x11Places) x11PlaceSave.restart()
    onYChanged: if (x11Places) x11PlaceSave.restart()
    Connections {
        target: miniWin
        enabled: root.x11Places
        function onXChanged() { x11PlaceSave.restart() }
        function onYChanged() { x11PlaceSave.restart() }
    }
    function applySavedSettings() {
        root.trackLayout = Settings.uiGet("library-layout", "grid")
        root.refreshShortcuts()
        root.miniPanelH = Number(Settings.uiGet("miniPanelHeight", 400))
        root.readWindowSettings()
        for (const w of [queueWin, visWin, videoWin]) w.restore()
        root.detached = ({ queue: queueWin.prefs().detached === true, vis: visWin.prefs().detached === true,
                           video: videoWin.prefs().detached === true })
        const plan = LayoutState.plan((k, f) => Settings.uiGet(k, f), WindowCtl.canPlaceWindows)
        root.restorePlan = plan
        root.restoringMini = plan.mini
        // a restored mini player: KWin maps main at opacity 0, as on X11
        WindowCtl.watchPopupWindows(true, plan.mini && !root.firstFrameShown)
        if (plan.mini) root.applyWindowOpacity()
        root.miniPopupVideo = Settings.uiGet("miniPopupVideo", false) === true
        if (npLoader.item) npLoader.item.showVideo = Settings.uiGet("npVideo", false) === true
        root.readVideoFit()
        PlayerState.videoWanted = root.videoWanted
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
        const saved = px !== -99999 && py !== -99999 ? { x: px, y: py } : null
        const start = LayoutState.mainStart(plan.maximized, saved, isX11, WindowCtl.canPlaceWindows)
        // a maximised main maximises on the screen of its saved place
        if (start.preplace && !root.firstFrameShown) {
            const at = LayoutState.onScreen(px, py, root.width, root.height, screenRects())
            if (at) { root.x = at.x; root.y = at.y }
        }
        if (start.maximizeNow && !root.firstFrameShown) root.visibility = Window.Maximized
        const place = () => {
            if (saved && root.visibility !== Window.Maximized) WindowCtl.applyMainPosition(px, py, start.maximizeByKwin)
            WindowCtl.watchMainGeometry()
            // reveal content only after the KWin position move, or the
            // window shows at KWin's default placement for a frame before
            // it jumps to the saved position
            const reveal = () => { playerBar.finishShown(); miniBar.finishShown(); root.ready = true; root.restoreLayout() }
            if (start.maximizeByKwin) whenMaximized(reveal)
            else reveal()
        }
        if (root.firstFrameShown) Qt.callLater(place)
        else root.placeWhenFramed = place
        sizeRestored = true
        // apply the saved EQ to the pipeline (window not needed)
        const eq = Settings.uiGet("eqConfig", null)
        if (eq) Player.applyEqConfig(eq)
        // restore volume into melo's own state rather than leaving it to
        // PulseAudio stream-restore, or PlayerState boots at 1.0 and the
        // first wheel step jumps to ~100%. Stored on the cubic scale as
        // volumeUi; an old linear "volume" save is converted once
        const savedVol = Settings.uiGet("volumeUi", -1)
        Player.setVolume(savedVol >= 0 ? Number(savedVol)
                                       : Math.cbrt(Number(Settings.uiGet("volume", 1))))
        // restore pin (KWin keepAbove doesn't survive the window going away)
        if (root.pinToggles && Settings.uiGet("alwaysOnTop", false) === true) {
            root.alwaysOnTop = true
            WindowCtl.setKeepAbove(true)
        }
        // first run: the look, the account, done — once, whether finished or skipped
        if (Settings.uiGet("onboardingDone", false) !== true)
            onboarding.open()
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
            // the final width can land while still frozen, where onWidthChanged skips this
            if (root.popupAnchorRight && Math.abs(root.width - miniWin.width) < 1) root.popupAnchorRight = false
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
    readonly property real fullContentOpacity: ((kwinSwap || !miniPlayer) && !restoringMini ? hoverFade : 0) * _r
    readonly property real fullBaseOpacity: fullContentOpacity
    readonly property real miniContentOpacity: ((kwinSwap || miniPlayer) ? miniHoverFade : 0) * _r
    readonly property bool fullBarVisible: !miniPlayer || toggling
    // expandReveal: the bar is still on screen until main has drawn at its full-size place
    readonly property bool miniVisible: (miniPlayer || toggling || expandReveal) && builtinMini
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

    // X11 shows a mapped window before anything is drawn in it, black; KWin starts
    // main at 0 there (watchPopupWindows) and it is revealed after its first frame
    property bool firstFrame: !isX11
    Connections {
        target: root
        enabled: !root.firstFrame
        function onFrameSwapped() { root.firstFrame = true; root.applyWindowOpacity() }
    }
    function applyWindowOpacity() {
        const mainOp = shellHidden || popupSwap === -1 || revealPending || !firstFrame || restoringMini ? 0
                     : ((!miniPlayer || miniQueueShown || popupSwap === 1) ? 1 : 0)
        const wins = [{ title: "melo",      opacity: mainOp },
                      { title: "melo-mini",
                        opacity: ((miniPlayer || expandReveal) && builtinMini && !shellHidden && !hideMiniBar) ? 1 : 0 }]
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
        if (miniPlayer && builtinMini && clickThrough) setInputToBadge(miniWin, miniClickBadge)
        else WindowCtl.setInputEnabled(miniWin, miniPlayer && builtinMini && !hideMiniBar)
        applyWindowOpacity()
    }
    // Click through: pointer input passes to what is behind, except over the
    // badge that turns it off. Not saved: a start is always clickable.
    property bool clickThrough: false
    onClickThroughChanged: { updateMainInput(); syncPluginMini() }
    function setInputToBadge(win, badge) {
        const p = badge.mapToItem(null, 0, 0)
        WindowCtl.setInputRegion(win, Math.round(p.x), Math.round(p.y),
                                 Math.round(badge.width), Math.round(badge.height))
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
            // a restored mini player goes where the bar was left instead
            const at = restoringMini && restorePlan ? restorePlan.miniAt : null
            const x11At = at && !WindowCtl.canPlaceWindows && isX11
                          ? LayoutState.onScreen(at.x, at.y, width, root.barH, screenRects()) : null
            if (at && WindowCtl.canPlaceWindows) WindowCtl.applyMiniGeometry(at.x, at.y, Math.round(width), root.barH)
            else if (x11At) { miniWin.x = x11At.x; miniWin.y = x11At.y }
            else WindowCtl.alignForCollapse(root.barH)
        } else {
            // X11: main, the popup's host, stays dark through the settle while the bar holds.
            // With the popup attached main is its tall host on Wayland too, and its first
            // full-size frames would land at the host's height.
            if (isX11 || miniQueueShown) { expandReveal = true; revealPending = true; revealReady = false; applyWindowOpacity() }
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
        // a restored mini player starts at its own layout: main was never on screen.
        // With no transition the revealed bar draws its own layout through the settle:
        // KWin shows the settle's last frame, cut to the window it lands in
        const plays = Theme.barTransition !== "none"
        handoverLayout = restoringMini || from === to ? "" : plays ? from : to
        const fromBack = miniPlayer ? Theme.backMini : mainBackingNow
        const toBack = miniPlayer ? mainBackingNow : Theme.backMini
        handoverBacking = restoringMini || fromBack === toBack ? "" : plays ? fromBack : toBack
        // the flip waits only for the window move to land
        toggleSettleTimer.interval = 50
        toggleSettleTimer.restart()
    }
    function completeToggle() {
        // collapse alignment already ran during the settle (see toggleMini);
        // expand aligns main here (its width settled over the last 50ms)
        if (miniPlayer) {
            miniVisWanted = false
            WindowCtl.alignForExpand(root.barH, Math.round(root.width), Math.round(root.lastFullHeight))
        }
        // Who is behind the flip now, set before the state that moves both
        // bars: the one being revealed plays the change, the one going dark
        // lands it. Reversed from the settle, where the revealed bar was the
        // hidden one taking the outgoing layout.
        playerBar.quiet = !miniPlayer     // collapsing: main is the one going dark
        miniBar.quiet = miniPlayer        // expanding: mini is
        const expanding = miniPlayer
        miniPlayer = !miniPlayer
        toggling = false
        // a frame at the full-size place; already there, no geometry arrives, so the next frame is it
        if (expanding && expandReveal) {
            revealReady = isX11 && x === miniWin.x && height === Math.round(lastFullHeight)
                          && y === miniWin.y + barH - Math.round(lastFullHeight)
            revealFallback.restart()
        }
        if (MELO_GEOM_DEBUG) console.warn("[swap] " + Date.now() + " to " + (miniPlayer ? "mini" : "full")
                                          + " popup " + miniQueueShown + " blur " + (wantBlur || contrastGlass) + " barShown " + miniVisible)
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
        // where the flip left the window now shown: neither move is the user's, so KWin's watcher misses it
        flipReport.restart()
        if (restoringMini) finishRestore()
    }
    Timer {
        id: flipReport
        interval: 250
        onTriggered: {
            if (root.toggling || root.sysDragging || root.resizeFreeze) return
            if (root.x11Places) x11PlaceSave.restart()
            else WindowCtl.reportMainGeometry()
        }
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
        if (Qt.platform.pluginName === "xcb") { WindowCtl.keepBufferInStep(root); WindowCtl.keepBufferInStep(miniWin) }
        if (Settings.loaded) applySavedSettings()
        // Once at startup, or it never runs at all: the window opens at the
        // size it was saved with, so nothing resizes it, and dprGeneration
        // cannot fire either -- its event filter arms on the first dprOf call,
        // which only happens in here. pushDpr makes it: snapSize returns before
        // it when snap is off.
        root.readGridSnap()
        root.pushDpr()
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
            if (root.toggling || ++root.prewarmTries > 8) { stop(); return }
            // Re-assert opacity too, in either mode: the onCompleted applyWindowOpacity()
            // can race mapping, and KWin starts the bar at 0 (watchPopupWindows).
            if (!root.miniPlayer) WindowCtl.alignForCollapse(root.barH)
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
    // the room above the bar, from KWin when the popup's host is fitted
    property real popupRoom: 1e6
    readonly property real popupMaxH: Math.min(height, popupRoom) - barH - miniQueueOverlay.gap
    Connections {
        target: WindowCtl
        function onPopupRoom(room) { root.popupRoom = room }
    }
    // The queue, the visualizer and the video, each in a window of its own: by
    // choice (Ctrl+drag off the popup, or its shortcut), and always where the popup
    // cannot sit under the bar. Any of them may be open at once.
    property var detached: ({ queue: false, vis: false, video: false })
    function inWindow(kind) { return detached[kind] === true || !WindowCtl.canPlaceWindows }
    function winOf(kind) { return kind === "queue" ? queueWin : kind === "vis" ? visWin : videoWin }
    function setDetached(kind, on) {
        const d = Object.assign({}, detached); d[kind] = on; detached = d
        winOf(kind).remember({ detached: on })
    }
    readonly property bool queueInWindow: inWindow("queue")
    property string detachedControls: "bar"
    property bool detachedHideBar: false
    function readWindowSettings() {
        detachedControls = Settings.uiGet("detachedControls", "bar") === "over" ? "over" : "bar"
        detachedHideBar = Settings.uiGet("detachedHideBar", false) === true
    }
    Connections { target: Settings; function onChanged() { root.readWindowSettings() } }
    readonly property bool anyWindowOpen: queueWin.open || visWin.open || videoWin.open
    // the mini bar hides by choice while a window is open; the last window closing brings it back
    readonly property bool hideMiniBar: miniPlayer && detachedHideBar && anyWindowOpen
    onHideMiniBarChanged: syncPluginMini()
    // what the attached popup shows
    readonly property string popupKind: !miniVisWanted ? "queue" : popupVideoMode ? "video" : "vis"
    // the visualizer in its window, unless it is on its way back under the bar
    readonly property bool vizInVisWin: visWin.open && !(popupSwap === -1 && swapWin === visWin)
    readonly property bool vizInPopup: miniVisWanted && miniQueueShown && !popupVideoMode

    // a window by its shortcut: closed, or opened (that kind detached); one the
    // attached popup is showing comes off it in place
    function toggleWindow(kind) {
        const w = winOf(kind)
        if (w.open) { w.hide(); return }
        if (miniQueueShown && popupKind === kind) { detachFromPopup(kind, false); return }
        if (!detached[kind] && WindowCtl.canPlaceWindows) setDetached(kind, true)
        if (kind === "queue" && miniPlayer) PlayerState.showPanel = false
        syncMiniQueue()
        w.show()
    }
    // The visualizer and the video share one place when only one is open: the
    // switch hands it to the other window, which takes this one's place and size.
    property var mediaSwap: null
    function swapMedia(to) {
        const from = to === "video" ? visWin : videoWin, dest = winOf(to)
        if (!from.open || dest.open) return
        setDetached(to, true)
        dest.width = from.width
        dest.height = from.height
        if (!dest.mapped) { from.hide(); dest.show(); return }
        mediaSwap = { from: from, to: dest }
        dest.open = true          // draws at opacity 0 first
        dest.awaitingFrame = true
        dest.applyGlass()
    }
    function finishMediaSwap() {
        const from = mediaSwap.from, dest = mediaSwap.to
        mediaSwap = null
        WindowCtl.swapPopupWindows(from.title, dest.title)
        WindowCtl.setInputEnabled(dest, true)
        WindowCtl.setInputEnabled(from, false)
        from.open = false
    }
    // Off the popup into its window where the popup was, then carried by the
    // pointer that is still down. Detaching and reattaching swap the windows in
    // one compositor step: the one going keeps its last frame (held) until the one
    // coming has drawn the content, then one KWin call shows one and hides the other.
    property point detachAt: Qt.point(0, 0)
    property int popupSwap: 0   // 1 detaching, -1 reattaching
    property var swapWin: null
    property bool detachCarry: false
    // X11, a Ctrl+drag: the press in screen terms, so the window lands as far from the
    // popup's place as the cursor has travelled (the drag threshold and the swap's frames)
    property var detachPress: null
    function detachFromPopup(kind, carry, pressAt) {
        const w = winOf(kind)
        detachPress = carry && isX11 && pressAt ? Qt.point(x + pressAt.x, y + pressAt.y) : null
        if (MELO_GEOM_DEBUG) {
            const c = WindowCtl.cursorPos()
            console.warn("[detach] " + Date.now() + " start cursor " + c.x + "," + c.y + " popup "
                         + Math.round(root.x + miniQueueOverlay.x) + "," + Math.round(root.y + miniQueueOverlay.y))
        }
        detachAt = Qt.point(miniQueueOverlay.x, miniQueueOverlay.y)
        w.width = miniQueueOverlay.width
        w.height = miniQueueOverlay.height
        const swap = miniQueueShown && w.mapped
        setDetached(kind, true)
        if (kind === "queue" && miniPlayer) PlayerState.showPanel = false
        if (!swap) { syncMiniQueue(); w.show(); return }
        WindowCtl.holdFrames(root, true)
        detachCarry = carry
        popupSwap = 1
        swapWin = w
        syncMiniQueue()              // main stays up, held on its last frame, until the swap
        w.open = true                // the content draws in the window, still at opacity 0
        w.awaitingFrame = true
        w.applyGlass()
    }
    function finishDetach(w) {
        popupSwap = 0
        swapWin = null
        let tx = detachAt.x, ty = detachAt.y
        if (detachPress) {
            const c = WindowCtl.cursorPos()
            tx += c.x - detachPress.x; ty += c.y - detachPress.y
            detachPress = null
        }
        WindowCtl.placePopupWindowOverMain(w.title, Math.round(tx), Math.round(ty))
        WindowCtl.setInputEnabled(w, true)
        WindowCtl.setWindowOpacities([{ title: w.title, opacity: 1 },
                                      { title: "melo", opacity: !miniPlayer || miniQueueShown ? 1 : 0 }])
        applyMainHold()
        if (MELO_GEOM_DEBUG) {
            const c = WindowCtl.cursorPos()
            console.warn("[detach] " + Date.now() + " swap cursor " + c.x + "," + c.y + " window " + w.x + "," + w.y
                         + " placed " + Math.round(root.x + tx) + "," + Math.round(root.y + ty) + " carry " + detachCarry)
        }
        // the press was on main: the new window has none of its own to start from
        if (detachCarry) { detachCarry = false; WindowCtl.startSystemMove(w, root) }
    }
    function showInPopup(kind) {
        if (kind === "queue") { miniVisWanted = false; PlayerState.showPanel = true; return }
        PlayerState.showPanel = false
        miniVisWanted = true
        miniPopupVideo = kind === "video"
        Settings.uiSet("miniPopupVideo", miniPopupVideo)
    }
    // back under the bar
    function reattach(w) {
        setDetached(w.kind, false)
        if (!miniPlayer || !w.mapped || !w.open) {
            w.hide()
            if (miniPlayer) { showInPopup(w.kind); syncMiniQueue() }
            return
        }
        WindowCtl.holdFrames(w, true)   // the window keeps its last frame
        popupSwap = -1
        swapWin = w
        showInPopup(w.kind)
        syncMiniQueue()                 // main stays at opacity 0 until it has drawn
    }
    function finishReattach() {
        const w = swapWin
        popupSwap = 0
        swapWin = null
        w.open = false
        WindowCtl.setInputEnabled(w, false)
        WindowCtl.setWindowOpacities([{ title: "melo", opacity: 1 }, { title: w.title, opacity: 0 }])
        WindowCtl.holdFrames(w, false)
        updateMainInput()
    }
    function windowFramed(w) {
        if (popupSwap === 1 && swapWin === w) finishDetach(w)
        else if (mediaSwap && mediaSwap.to === w) finishMediaSwap()
    }
    Connections {
        target: root.popupSwap === -1 ? root : null
        // two frames can land before the target drops: only the first finishes
        function onFrameSwapped() { if (root.popupSwap === -1) root.finishReattach() }
    }
    Connections {
        target: WindowCtl
        function onPopupWindow(caption, x, y, w, h, nearBar) {
            if (root.detachedResizing) root.endDetachedResize()
            const win = caption === "melo-queue" ? queueWin : caption === "melo-vis" ? visWin
                      : caption === "melo-video" ? videoWin : null
            if (win) win.reported(x, y, w, h, nearBar && root.miniPlayer)
        }
    }
    // the popup region hosts EITHER the queue or the mini visualizer
    property bool miniVisWanted: false
    property bool miniPopupVideo: false
    // the saved choice stays; without video support the popup shows the visualizer
    readonly property bool popupVideoMode: miniPopupVideo && PlayerState.videoSupported
    readonly property bool videoWanted: VideoWanted.wanted(PlayerState.view, root.miniPlayer,
        npLoader.item ? npLoader.item.showVideo : false,
        root.miniVisWanted, root.miniQueueShown, root.popupVideoMode,
        root.toggling && root.miniPlayer) || videoWin.open
    onVideoWantedChanged: PlayerState.videoWanted = videoWanted
    // A bar resize with the popup open widens its host to that side first; the popup
    // keeps to the bar's right edge through a drag from the left. Cleared once the
    // host is the bar's width again, where both placements are the same.
    property bool popupAnchorRight: false
    function beginPopupResize(edges) {
        if (!miniQueueShown) return
        // X11's host spans the screen and the popup follows the bar's place; after a
        // move carried it off, it is refitted here, hidden until drawn at its new place
        if (isX11) {
            const a = WindowCtl.availableGeometry(miniWin)
            if (a.width > 0 && (x > a.x || x + width < a.x + a.width)) {
                revealPending = true; revealReady = false
                applyWindowOpacity()
                revealFallback.restart()
                WindowCtl.fitPopupHost("")
            }
            return
        }
        // The host stays widened after a drag, so a drag on the same side needs nothing.
        // A refit that moves it (the other side, or onto the left) is hidden until drawn:
        // KWin shows a moved window's last frame, the popup where it was.
        const needRight = (edges & Qt.LeftEdge) !== 0
        if (width > miniWin.width + 1 && needRight === popupAnchorRight) return
        if (needRight || popupAnchorRight) {
            revealPending = true; revealReady = false
            applyWindowOpacity()
            revealFallback.restart()
        }
        popupAnchorRight = needRight
        WindowCtl.fitPopupHost(needRight ? "left" : "right")
    }
    // The popup renders inside main, so main is widened to the bar's width when
    // the popup opens and when a bar resize ends.
    function ensureMainWideEnough() {
        if (miniPlayer && width < miniWin.width) width = miniWin.width
    }
    property bool revealPending: false
    // set when main's geometry is current: already the wide host, or a new geometry arrived
    property bool revealReady: false
    // the host covers the bar: drawn where it stands, so no old picture moves with it
    readonly property bool hostOverBar: root.x <= miniWin.x && root.x + root.width >= miniWin.x + miniWin.width
    Timer {   // in case no geometry ever arrives
        id: revealFallback
        interval: 150
        onTriggered: if (root.revealPending) root.finishReveal()
    }
    // expanding on X11: the bar stays up until main has drawn at its full-size place
    property bool expandReveal: false
    function finishReveal() {
        revealPending = false
        expandReveal = false
        if (MELO_GEOM_DEBUG) console.warn("[reveal] " + Date.now() + " main " + x + " w " + width)
        applyWindowOpacity()
        applyBlur()
    }
    Connections {
        target: root.revealPending ? root : null
        function onXChanged() { root.revealReady = true }
        function onYChanged() { root.revealReady = true }
        function onWidthChanged() { root.revealReady = true }
        function onHeightChanged() { root.revealReady = true }
        function onFrameSwapped() {
            if (root.revealReady && (root.expandReveal ? !root.miniPlayer : !root.isX11 || root.hostOverBar)) root.finishReveal()
        }
    }
    // X11: KWin raises only the bar on a click, so the attached popup is put directly under it
    function raisePopupHost(why) {
        if (!isX11 || !miniQueueShown) return
        if (MELO_GEOM_DEBUG) console.warn("[stack] " + Date.now() + " " + why + " before " + WindowCtl.stackOrder(root, miniWin))
        WindowCtl.restackBelow(root, miniWin)
        if (MELO_GEOM_DEBUG) stackAfter.restart()
    }
    Timer {
        id: stackAfter
        interval: 150
        onTriggered: console.warn("[stack] " + Date.now() + " after " + WindowCtl.stackOrder(root, miniWin))
    }
    function syncMiniQueue() {
        // no popup where melo cannot place windows: toggleQueue expands instead
        const want = WindowCtl.canPlaceWindows && miniPlayer && PlayerState.hasTrack
                     && ((PlayerState.showPanel && !detached.queue)
                         || (miniVisWanted && !detached[popupVideoMode ? "video" : "vis"]))
        if (want) ensureMainWideEnough()
        if (want && !miniQueueShown) {
            // X11 shows main's last picture at the host's new place until it draws
            // again, so main stays clear until a frame at the new size lands
            if (isX11) {
                revealReady = hostOverBar && width > miniWin.width + 1
                revealPending = true; revealFallback.restart(); requestUpdate()
                if (MELO_GEOM_DEBUG) console.warn("[open] " + Date.now() + " ready " + revealReady + " main " + x + " w " + width)
            }
            popupAnchorRight = false               // the host is fitted to the bar's span
            WindowCtl.fitPopupHost("")             // blocking; invisible while it happens
            WindowCtl.setMiniQueueGlue(true)       // follow bar drags
        } else if (!want && miniQueueShown) {
            if (!expandReveal) revealPending = false
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
            if (clickThrough) setInputToBadge(root, mainClickBadge)
            else WindowCtl.setInputEnabled(root, true)
        } else if (miniQueueShown && clickThrough) {
            WindowCtl.setInputEnabled(root, false)
        } else if (miniQueueShown) {
            WindowCtl.setInputRegion(root, miniQueueOverlay.x, miniQueueOverlay.y,
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
        if (popupAnchorRight && !resizeFreeze && Math.abs(width - miniWin.width) < 1) popupAnchorRight = false
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
    // MELO_GEOM_DEBUG=1: the popup's screen x on each frame main draws, against the bar's
    // ("off" is popup x minus bar x: 0 is in place); the bar's own moves in between
    Connections {
        target: MELO_GEOM_DEBUG ? root : null
        function onFrameSwapped() {
            if (!root.miniQueueShown) return
            const px = root.x + miniQueueOverlay.x
            console.warn("[pop] " + Date.now() + " main " + root.x + "," + root.y + " " + root.width + "x" + root.height
                         + " bar " + miniWin.x + "," + miniWin.y + " " + miniWin.width
                         + " popX " + px + " off " + Math.round(px - miniWin.x)
                         + " anchorR " + root.popupAnchorRight + " freeze " + root.resizeFreeze + " drag " + root.sysDragging
                         + " hidden " + root.revealPending)
        }
        function onXChanged() { if (root.miniQueueShown) console.warn("[main] " + Date.now() + " x " + root.x + " w " + root.width) }
    }
    // MELO_GEOM_DEBUG: the queue window's right-hand edges, per frame it draws, in window
    // coordinates; every one should sit at the body's right edge on every frame
    Connections {
        target: MELO_GEOM_DEBUG ? queueWin : null
        function onFrameSwapped() {
            if (!root.queueInWindow) return
            const b = queueWin.body, q = popupQueuePanel
            const r = (it) => it ? Math.round(it.mapToItem(null, it.width, 0).x * 10) / 10 : -1
            console.warn("[qedge] " + Date.now() + " win " + queueWin.width + "x" + queueWin.height
                         + " body " + r(b) + " panel " + r(q) + " " + q.edgeReport())
        }
    }
    Connections {
        target: MELO_GEOM_DEBUG ? miniWin : null
        function onXChanged() { console.warn("[bar] " + Date.now() + " x " + miniWin.x + " w " + miniWin.width) }
        function onWidthChanged() { console.warn("[bar] " + Date.now() + " x " + miniWin.x + " w " + miniWin.width) }
    }
    Connections {
        target: MELO_GEOM_DEBUG ? WindowCtl : null
        function onInteractiveStarted() { console.warn("[drag] " + Date.now() + " start") }
        function onMainGeometry(x, y, w, h) { console.warn("[drag] " + Date.now() + " end main " + x + "," + y + " " + w + "x" + h) }
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
    // A contrast the compositor can only apply through the blur effect has
    // to re-ask for that effect when it changes. Only KWin 6.6 and older have
    // contrast; elsewhere a contrast setting must not turn blur on.
    readonly property bool contrastGlass: Theme.wantContrast && WindowCtl.contrastAvailable
    onContrastGlassChanged: applyBlur()
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
        // through an expand's reveal the bar is still up, so it keeps its glass
        glassOn(miniWin, (wantBlur || contrastGlass) && (miniPlayer || expandReveal) && builtinMini)
        // Contrast needs glass: Plasma 6.5 merged background contrast into the blur
        // effect, so a surface that requests no blur gets no contrast. A non-default
        // contrast therefore requests blur too, at KWin's global strength.
        if (!wantBlur && !contrastGlass) { glassOn(root, false); return }
        if (!miniPlayer) glassOn(root, true)
        else if (miniQueueShown) {
            WindowCtl.setBlurRegion(root, miniQueueOverlay.x, miniQueueOverlay.y,
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
            readonly property Item readItem: groundRead.texture
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
        GroundPictures { id: groundRead; base: ground }
    }

    // mini-mode queue: rendered by the (otherwise invisible) main window,
    // sitting exactly above where the mini bar overlaps main's bar region
    Shortcut {
        sequence: "Escape"
        enabled: root.miniQueueShown
        onActivated: { PlayerState.showPanel = false; root.miniVisWanted = false }
    }
    // popup height is user-resizable (top edge and top corners) and persisted
    property int miniPanelH: 400
    // A popup corner drag: the bar's width through KWin's resize, the popup's
    // height from KWin's cursor reports, less where in the corner it was grabbed.
    property bool popupCornerDrag: false
    property real popupCornerGrab: NaN
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
        // under the bar: from main's left, or through a drag from the left, from its
        // right, where the bar's fixed edge is (see fitPopupHost). X11 gives both
        // windows' places, so there it follows the bar itself: KWin moves and sizes the
        // host in separate steps, and the anchor alone would draw it in the wrong place for a frame
        x: root.isX11 && root.miniPlayer
           ? Math.max(0, Math.min(root.width - width, miniWin.x - root.x))
           : root.popupAnchorRight ? root.width - width : 0
        // width follows the BAR live — but ONLY while shown: a hidden overlay tracking the bar per drag
        // frame re-layouts its ListView, and the polish request schedules
        // real (empty) frames on main — sibling chatter during the resize
        width: !root.miniQueueShown ? 400
             : root.miniPlayer ? miniWin.width
             : root.width
        // a SEPARATE rounded card: a small gap above the bar (only when the
        // corners are rounded — squared themes stay flush/continuous)
        readonly property int gap: root.cornerRadius > 0 ? 6 : 0
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.barH + gap
        height: Math.max(120, Math.min(root.miniPanelH, root.popupMaxH))
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
                WindowCtl.setBlurRegion(root, x, y, width, height)
            }
            regionSyncTimer.restart()
        }
        onHeightChanged: trackRegions()
        onWidthChanged: trackRegions()
        onXChanged: trackRegions()
        onYChanged: trackRegions()
        Timer {
            id: regionSyncTimer
            interval: 150
            // Final region once the popup settles: a change during an in-flight commit,
            // or a binding settling a frame after the drag, otherwise leaves the blur
            // behind with nothing to correct it.
            onTriggered: if (root.miniQueueShown) {
                if (root.wantBlur)
                    WindowCtl.setBlurRegion(root, miniQueueOverlay.x, miniQueueOverlay.y,
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
                root.miniPanelH = Math.max(120, Math.min(root.popupMaxH, (root.height - root.barH) - gy))
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
        Item {   // Ctrl+drag takes the popup off into its own window
            anchors.fill: parent
            z: 20
            DragHandler {
                target: null
                acceptedModifiers: Qt.ControlModifier
                grabPermissions: PointerHandler.CanTakeOverFromAnything   // a queue row holds its press
                onActiveChanged: if (active) root.detachFromPopup(root.popupKind, true, centroid.scenePressPosition)
            }
        }
        // The popup is a card in the bar's style: the theme's corners cut it and
        // the theme's frame goes round it, whatever it shows.
        WindowShape {
            id: popupShape
            anchors.fill: parent
            z: 1000
            input: false   // the window's input is updateMainInput's
            spec: Theme.panelShapeFor(Theme.windowRadius, Theme.windowRadius)
            active: spec !== null
        }
        WindowBorder {
            anchors.fill: parent
            z: 999
            borderLeft: root.frL; borderTop: root.frT; borderRight: root.frR; borderBottom: root.frB
            radiusTL: Theme.windowRadius; radiusTR: Theme.windowRadius
            radiusBL: Theme.windowRadius; radiusBR: Theme.windowRadius
            shape: popupShape.active ? popupShape : null
            visible: root.frameDrawn
        }
        // The popup's sides are the bar's: a press there is the bar's own resize.
        Repeater {
            model: [Qt.LeftEdge, Qt.RightEdge]
            MouseArea {
                required property int modelData
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: 12
                x: modelData === Qt.LeftEdge ? 0 : parent.width - width
                width: 5
                z: 11
                cursorShape: Qt.SizeHorCursor
                onPressed: (m) => {
                    root.beginResizeHold()
                    root.beginPopupResize(modelData)
                    WindowCtl.startSystemResize(miniWin, modelData, root)
                }
            }
        }
        Repeater {   // top corners: the bar's width and the popup's height together
            model: [Qt.LeftEdge, Qt.RightEdge]
            MouseArea {
                required property int modelData
                x: modelData === Qt.LeftEdge ? 0 : parent.width - width
                width: 12
                height: 12
                z: 12
                cursorShape: modelData === Qt.LeftEdge ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                onPressed: (m) => {
                    root.popupCornerGrab = NaN
                    root.popupCornerDrag = true
                    root.beginResizeHold()
                    // A corner, so KWin draws the diagonal cursor through the drag;
                    // the bar's height is pinned for it, and only for it.
                    miniWin.maximumHeight = miniWin.height
                    miniWin.minimumHeight = miniWin.height
                    root.beginPopupResize(modelData)
                    WindowCtl.startSystemResize(miniWin, modelData | Qt.TopEdge, root)
                }
            }
        }
        Connections {
            target: WindowCtl
            enabled: root.popupCornerDrag
            function onPopupCursor(above) {
                if (isNaN(root.popupCornerGrab)) root.popupCornerGrab = above - miniQueueOverlay.height
                root.miniPanelH = Math.max(120, Math.min(root.popupMaxH, above - root.popupCornerGrab))
                panelHSaveTimer.restart()
            }
            function onMainGeometry() {
                root.popupCornerDrag = false
                miniWin.minimumHeight = 0
                miniWin.maximumHeight = 16777215   // QWINDOWSIZE_MAX
            }
        }
        Item {   // under the queue: a right click its rows leave opens the popup's menu
            anchors.fill: parent
            visible: !root.miniVisWanted && !root.queueInWindow
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: (ev) => {
                    const g = parent.mapToItem(null, ev.position.x, ev.position.y)
                    root.openPopupMenu(g.x, g.y)
                }
            }
        }
        QueuePanel {
            id: popupQueuePanel
            parent: root.queueInWindow ? queueWin.body : miniQueueOverlay
            anchors.fill: parent
            // inside the popup's frame, as the bar sits inside its own; the
            // window's body is inside its frame already
            anchors.leftMargin: root.queueInWindow ? 0 : root.frL
            anchors.topMargin: root.queueInWindow ? 0 : root.frTop
            anchors.rightMargin: root.queueInWindow ? 0 : root.frR
            anchors.bottomMargin: root.queueInWindow ? 0 : root.frB
            visible: root.queueInWindow ? queueWin.open : !root.miniVisWanted
            fullWidth: true
            miniHost: true
            contextMenu: contextMenu   // main-window overlays work in mini mode
            menuHost: root.queueInWindow ? queueWin : null
            menuTail: root.queueInWindow ? () => root.windowActs(queueWin) : root.popupActs
        }
        Surface {   // visualizer popup backing (the shared viz reparents in)
            id: miniVisSlot
            anchors.fill: parent
            visible: root.miniVisWanted
            role: "window"
            // The card's corners and frame are the popup's (popupShape); what it holds
            // sits inset by the radius, clear of a cut or rounded corner.
            // the skeleton shows only before there is video, so it can sit over the picture
            GroundPicture {
                anchors.fill: parent
                anchors.margins: Theme.windowRadius
                visible: root.popupVideoMode
                Image {   // under the video, for stills and the first beat
                    anchors.fill: parent
                    source: PlayerState.trackThumbnail
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: 1 - popupVideo.fade
                    visible: opacity > 0.01
                }
                VideoSurface {
                    id: popupVideo
                    anchors.fill: parent
                    running: root.popupVideoMode && root.miniVisWanted && root.miniQueueShown
                             && PlayerState.hasVideo
                    frozen: root.resizeFreeze || !PlayerState.isPlaying
                    fit: root.videoFit
                    property real fade: hasFrame ? 1 : 0
                    Behavior on fade { NumberAnimation { duration: 300 } }
                    opacity: fade * Theme.videoOpacity
                    visible: opacity > 0.01
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        enabled: popupVideo.fade > 0.5
                        onTapped: (ev) => {
                            const g = popupVideo.mapToItem(null, ev.position.x, ev.position.y)
                            root.openVideoMenu(g.x, g.y, root)
                        }
                    }
                }
            }
            Skeleton {
                anchors.fill: parent
                anchors.margins: Theme.windowRadius
                radius: Theme.windowRadius
                shimmer: true
                opacity: 0.6
                visible: root.popupVideoMode && (PlayerState.videoPending || PlayerState.loading) && !PlayerState.hasVideo
            }
            PopupModeToggle {
                anchors.top: parent.top
                anchors.left: parent.left
                // the gear's inset: the card's corner, then the gap
                anchors.margins: Math.max(1, Theme.windowRadius) + Theme.gap(10)
                z: 10
                video: root.miniPopupVideo
                visible: PlayerState.videoSupported
                opacity: overlayHover.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                onPicked: (v) => { root.miniPopupVideo = v; Settings.uiSet("miniPopupVideo", v) }
            }
        }
    }

    DetachedWindow {
        id: queueWin
        kind: "queue"
        failShown: root.failHost === kind
        failChoices: root.failBrowsers
        failBusy: root.failChecking
        failStale: root.ytdlpStale.length > 0
        onFailAnswered: (a) => root.answerFailure(a)
        listEmpty: popupQueuePanel.empty
        defaultControls: root.detachedControls
        onFrameShown: root.windowFramed(queueWin)
        recordOpen: root.layoutRecording
        onReattachRequested: root.reattach(queueWin)
        onResizeStarting: root.beginDetachedResize(queueWin)
        onMenuRequested: (x, y) => root.openWindowMenu(queueWin, x, y)
    }
    DetachedWindow {
        id: visWin
        kind: "vis"
        failShown: root.failHost === kind
        failChoices: root.failBrowsers
        failBusy: root.failChecking
        failStale: root.ytdlpStale.length > 0
        onFailAnswered: (a) => root.answerFailure(a)
        defaultControls: root.detachedControls
        onFrameShown: root.windowFramed(visWin)
        recordOpen: root.layoutRecording
        onReattachRequested: root.reattach(visWin)
        onResizeStarting: root.beginDetachedResize(visWin)
        onMenuRequested: (x, y) => root.openWindowMenu(visWin, x, y)
        Item { id: visSlot; parent: visWin.body; anchors.fill: parent }   // the shared viz reparents in
        Row {   // on hover: Visualizer | Video while the video has no window
            parent: visWin.body
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: Math.max(1, Theme.windowRadius) + Theme.gap(10)
            z: 25
            spacing: Theme.gap(6)
            opacity: visWin.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
            PopupModeToggle {
                visible: PlayerState.videoSupported && !videoWin.open
                video: false
                onPicked: (v) => { if (v) root.swapMedia("video") }
            }
        }
        OverlayControls {
            parent: visWin.body
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            // as far in as the row at the top: its faces sit inside a segment track,
            // and a shaped window's body runs under the bottom frame
            anchors.bottomMargin: Math.max(1, Theme.windowRadius) + Theme.gap(10) + (Theme.toggles === "segment" ? Theme.tabTrackPad : 0)
                                  + (visWin.shaped ? visWin.frB : 0)
            z: 20
            shown: visWin.overlay && visWin.open && visWin.hovered
        }
    }
    DetachedWindow {
        id: videoWin
        kind: "video"
        failShown: root.failHost === kind
        failChoices: root.failBrowsers
        failBusy: root.failChecking
        failStale: root.ytdlpStale.length > 0
        onFailAnswered: (a) => root.answerFailure(a)
        defaultControls: root.detachedControls
        onFrameShown: root.windowFramed(videoWin)
        recordOpen: root.layoutRecording
        onReattachRequested: root.reattach(videoWin)
        onResizeStarting: root.beginDetachedResize(videoWin)
        onMenuRequested: (x, y) => root.openWindowMenu(videoWin, x, y)
        GroundPicture {
            parent: videoWin.body
            anchors.fill: parent
            visible: videoWin.open
            Image {   // under the video, for stills and the first beat
                anchors.fill: parent
                source: PlayerState.trackThumbnail
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                opacity: 1 - windowVideo.fade
                visible: opacity > 0.01
            }
            VideoSurface {
                id: windowVideo
                anchors.fill: parent
                running: videoWin.open && PlayerState.hasVideo
                frozen: root.resizeFreeze || !PlayerState.isPlaying
                fit: root.videoFit
                property real fade: hasFrame ? 1 : 0
                Behavior on fade { NumberAnimation { duration: 300 } }
                opacity: fade * Theme.videoOpacity
                visible: opacity > 0.01
            }
        }
        Row {
            parent: videoWin.body
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: Math.max(1, Theme.windowRadius) + Theme.gap(10)
            z: 25
            spacing: Theme.gap(6)
            opacity: videoWin.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
            PopupModeToggle {
                visible: MELO_HAS_GL && !visWin.open
                video: true
                onPicked: (v) => { if (!v) root.swapMedia("vis") }
            }
        }
        OverlayControls {
            parent: videoWin.body
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            // as far in as the row at the top: its faces sit inside a segment track,
            // and a shaped window's body runs under the bottom frame
            anchors.bottomMargin: Math.max(1, Theme.windowRadius) + Theme.gap(10) + (Theme.toggles === "segment" ? Theme.tabTrackPad : 0)
                                  + (videoWin.shaped ? videoWin.frB : 0)
            z: 20
            shown: videoWin.overlay && videoWin.open && videoWin.hovered
        }
    }

    Window {
        id: miniWin
        onActiveChanged: {
            if (MELO_FOCUS_DEBUG) console.log("[focus-debug] miniWin.active", active)
            if (active) root.raisePopupHost("active")
        }
        transientParent: root
        PointHandler {   // a press on the bar, active or not, brings the attached popup up with it
            enabled: root.isX11 && root.miniQueueShown
            onActiveChanged: if (active) root.raisePopupHost("press")
        }
        width: 1000     // kept in sync with main while hidden (pure-move constraint)
        height: root.barH
        minimumWidth: 320
        color: "transparent"
        title: "melo-mini"    // distinct title (bg-rule exclusion, future rules)
        flags: Qt.Window | Qt.FramelessWindowHint
        visible: true

        HoverHandler { id: miniHover; enabled: root.miniPlayer }
        PlayFailDialog {
            parent: miniWin.contentItem
            z: 9500
            shown: root.failHost === "mini" && root.miniPlayer
            cause: PlayerState.failCause
            reason: PlayerState.failReason
            stale: root.ytdlpStale.length > 0
            choices: root.failBrowsers
            busy: root.failChecking
            onAnswered: (a) => root.answerFailure(a)
        }
        ClickThroughBadge {
            id: miniClickBadge
            parent: miniWin.contentItem
            // the bar has no title row: "title" is its top right
            x: Theme.lockPlace === "left" ? Theme.gap(4)
             : Theme.lockPlace === "centre" ? (parent.width - width) / 2
             : parent.width - width - Theme.gap(4)
            y: look === "tab" ? 0 : Theme.gap(4)
            z: 9000
            visible: root.clickThrough && root.miniPlayer
            onXChanged: if (visible) root.syncPluginMini()
            onYChanged: if (visible) root.syncPluginMini()
            onReleased: root.clickThrough = false
        }
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
                root.beginResizeHold()
                root.beginPopupResize(e)
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
            // root.barH reads this: the mini slot's height, never the handover's
            settleLayout: "barMini:" + Theme.barMini
            barMenu: (sx, sy, host) => root.openBarMenu(sx, sy, host)
            anchors.fill: parent
            // inside a frame round the mini window; a framed card moves in itself
            readonly property bool framedWindow: !(Theme.windowBorderFit === "parts" && shownBacking === "floating")
            // A shaped window is filled, not inset: the shape cuts the
            // backing and the frame is drawn over it, where a backing inset by
            // the frame left the cut corners empty
            readonly property bool shaped: miniShape.active && miniShape.hasShape
            anchors.leftMargin: framedWindow && !shaped ? root.frL : 0
            anchors.topMargin: framedWindow && !shaped ? root.frTop : 0
            anchors.rightMargin: framedWindow && !shaped ? root.frR : 0
            anchors.bottomMargin: framedWindow && !shaped ? root.frB : 0
            edgeRadius: shaped ? 0
                      : framedWindow ? Math.max(0, Theme.windowRadius - Math.max(root.frL, root.frT, root.frR, root.frB)) : Theme.windowRadius
            mini: true
            cutLeft: shaped ? Math.max(root.frL, root.miniCutL) : 0
            cutRight: shaped ? Math.max(root.frR, root.miniCutR) : 0
            cutTop: framedWindow && shaped ? root.frTop : 0
            cutBottom: framedWindow && shaped ? root.frB : 0
            otherCutLeft: playerBar.cutLeft
            otherCutRight: playerBar.cutRight
            otherCutTop: playerBar.cutTop
            otherCutBottom: playerBar.cutBottom
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
            visActive: (root.miniVisWanted && root.miniQueueShown) || visWin.open || videoWin.open
            visAllowed: MELO_HAS_GL
            onQueueToggle: CommandMap.invoke("toggleQueue")
            onVisToggle: CommandMap.invoke("toggleVisualizer")
            onEqToggle: CommandMap.invoke("toggleEq")
            onDragStarted: root.holdFadeForDrag()
        }
    }

    // Popup-as-subsurface of the bar is WORSE than the toplevel popup: Qt
    // subsurfaces are desynchronized, so the child's commits collide with the
    // parent's resize inside one composited unit (tearing).

    // ---------- layout (opacity-gated by mini state; window never unmaps) ----------
    PlayerBar {
        barMenu: (sx, sy, host) => root.openBarMenu(sx, sy, host)
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
        cutBottom: root.shaped ? root.barInB : 0
        otherCutLeft: miniBar.cutLeft
        otherCutRight: miniBar.cutRight
        otherCutTop: miniBar.cutTop
        otherCutBottom: miniBar.cutBottom
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
        visActive: visWin.open || videoWin.open
        visAllowed: MELO_HAS_GL
        onQueueToggle: CommandMap.invoke("toggleQueue")
        onVisToggle: CommandMap.invoke("toggleVisualizer")
        onEqToggle: CommandMap.invoke("toggleEq")
        onDragStarted: root.holdFadeForDrag()
        onNeutralClick: if (PlayerState.view === 5 && npLoader.item && npLoader.item.videoShown) npLoader.item.toggleOverlay()
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
    // The first-run yt-dlp download, over every page: any play that needs
    // yt-dlp waits on it. Sits clear of the bar's volume toast.
    Surface {
        id: ytdlpToast
        readonly property real mb: 1048576
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: playerBar.settledHeight + root.barFoot + root.barRingTop + root.upperFoot
                              + Theme.gap(44)
        width: ytdlpToastText.implicitWidth + Theme.inset("toast", "left") + Theme.inset("toast", "right")
        // 16 is the row the words sit in
        height: Theme.inset("toast", "top") + 16 + Theme.inset("toast", "bottom")
        radius: Theme.radiusMd
        role: "toast"
        visible: sidecar.ytdlpState === "downloading" && root.fullBarVisible
        opacity: root.fullContentOpacity
        z: 12
        InkText {
            id: ytdlpToastText
            x: Theme.inset("toast", "left")
            y: Theme.inset("toast", "top") + (16 - implicitHeight) / 2
            ink: "text"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily; features: { "tnum": 1 } }
            text: {
                const got = sidecar.ytdlpReceived, total = sidecar.ytdlpTotal
                if (got <= 0) return "Downloading yt-dlp"
                const size = (got / ytdlpToast.mb).toFixed(1)
                return "Downloading yt-dlp  " + (total > 0 ? size + " / " + (total / ytdlpToast.mb).toFixed(1) : size) + " MB"
            }
        }
    }
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
        anchors.bottomMargin: playerBar.settledHeight + root.barFoot + root.barRingTop + root.upperFoot
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
            onNewProfileRequested: mainTitle.newProfile("New profile name", "")
            // a refused name is asked again with what was wrong
            function newProfile(title, initial) {
                promptDialog.promptDialog(title, initial, (name) => {
                    if (!name || !name.trim()) return
                    const n = name.trim()
                    sidecar.rpc("cookies/create", { name: n }, (r) => {
                        if (!r.ok) { mainTitle.newProfile(String(r.error), n); return }
                        Settings.cookieProfile = n
                        Settings.cookieSource = "guest"
                    })
                })
            }
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
            pinMode: WindowCtl.pinMode
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
            height: root.showSearch ? (root.showFilters ? rowH + filterRow.height + 4 : rowH) : 0
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
                menu: filterMenu
                onClicked: {
                    const p = fs.mapToItem(null, 0, fs.height + 2)
                    filterMenu.openAt(root, p.x, p.y, fs.options.map(o =>
                        ({ label: o.label, act: () => fs.picked(o.value) })), fs)
                }
            }
            DropMenu { id: filterMenu }
            // wraps onto more lines in a narrow window
            Flow {
                id: filterRow
                y: searchBarRect.rowH + 2
                anchors.left: parent.left
                anchors.leftMargin: Theme.inset("header", "left") + searchBarRect.cutL
                width: parent.width - anchors.leftMargin - Theme.inset("header", "right") - searchBarRect.cutR
                spacing: Theme.gap(10)
                visible: root.showFilters

                component FilterGroup: Row {
                    property alias label: fgLabel.text
                    default property alias content: fgSlot.data
                    spacing: Theme.gap(4)
                    height: 26
                    InkText { id: fgLabel; anchors.verticalCenter: parent.verticalCenter
                           ink: "textDim"
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                    Item { id: fgSlot; width: childrenRect.width; height: 22
                           anchors.verticalCenter: parent.verticalCenter }
                }
                FilterGroup { label: "Type"; visible: root.musicSearch
                    FilterSelect { value: root.searchType; onPicked: (v) => root.searchType = v
                        options: [ { value: "any", label: "Any" },
                                   { value: "song", label: "Songs" },
                                   { value: "video", label: "Videos" },
                                   { value: "album", label: "Albums" },
                                   { value: "playlist", label: "Playlists" } ] } }
                FilterGroup { label: "Sort"; visible: !root.musicSearch
                    FilterSelect { value: root.searchSort; onPicked: (v) => root.searchSort = v
                        options: [ { value: "relevance", label: "Relevance" },
                                   { value: "date", label: "Upload date" },
                                   { value: "views", label: "View count" },
                                   { value: "rating", label: "Rating" } ] } }
                FilterGroup { label: "Type"; visible: !root.musicSearch
                    FilterSelect { value: root.searchType; onPicked: (v) => root.searchType = v
                        options: [ { value: "any", label: "Any" },
                                   { value: "video", label: "Video" },
                                   { value: "playlist", label: "Playlist" },
                                   { value: "channel", label: "Channel" },
                                   { value: "movie", label: "Movie" } ] } }
                FilterGroup { label: "Upload date"; visible: !root.musicSearch
                    FilterSelect { value: root.searchDate; onPicked: (v) => root.searchDate = v
                        options: [ { value: "any", label: "Any time" },
                                   { value: "hour", label: "Last hour" },
                                   { value: "today", label: "Today" },
                                   { value: "week", label: "This week" },
                                   { value: "month", label: "This month" },
                                   { value: "year", label: "This year" } ] } }
                FilterGroup { label: "Duration"; visible: !root.musicSearch
                    FilterSelect { value: root.searchDuration; onPicked: (v) => root.searchDuration = v
                        options: [ { value: "any", label: "Any" },
                                   { value: "short", label: "Under 4 min" },
                                   { value: "medium", label: "4-20 min" },
                                   { value: "long", label: "Over 20 min" } ] } }
                InkText {
                    visible: root.hasFilters
                    height: 26
                    verticalAlignment: Text.AlignVCenter
                    text: "Clear"
                    ink: fcMa.containsMouse ? "text" : "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    MouseArea { id: fcMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: root.clearFilters() }
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
                    id: vizLoader
                    active: MELO_HAS_GL
                    sourceComponent: Visualizer {
                        id: viz
                        parent: root.vizInVisWin ? visSlot : root.vizInPopup ? miniVisSlot : vizSlot
                        anchors.fill: parent
                        // ...unless a plugin occupies the slot. Bound means
                        // INSTEAD OF, not on top of — two visualisers drawing
                        // the same audio in the same rectangle is the failure
                        // mode a slot exists to avoid.
                        visible: !root.vizSlotFilled
                                 && ((PlayerState.view === 4 && !root.miniPlayer)
                                     || root.vizInVisWin || root.vizInPopup)
                        // inset inside the rounded card so its square corners
                        // clear the card's rounded corners (max(1) keeps a
                        // 1px top gap in the mini slot)
                        anchors.margins: parent === miniVisSlot
                            ? Math.max(1, Theme.windowRadius) : 0
                        opacity: Theme.visualizerOpacity
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
                            acceptedButtons: root.vizInVisWin ? Qt.LeftButton : Qt.LeftButton | Qt.RightButton
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
                        property bool playingHint: PlayerState.isPlaying && !root.resizeFreeze   // holds through a resize
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
                    onOpenPlaylist: (pid, title, album) => root.openPlaylistOrPlay(pid, title, album)
                    onPlaylistMenu: (pid, title, album, sx, sy) => root.openPlaylistMenu(pid, title, album, sx, sy)
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
                    id: homeView
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 0
                    contextMenu: contextMenu
                    trackMenu: (t, sx, sy) => root.openTrackMenu(t, sx, sy)
                    layout: root.trackLayout
                    onChangeLayout: (mode) => root.changeTrackLayout(mode)
                    onOpenPlaylist: (playlistId, title, album) => root.openPlaylistOrPlay(playlistId, title, album)
                    onPlaylistMenu: (pid, title, album, sx, sy) => root.openPlaylistMenu(pid, title, album, sx, sy)
                }

                Loader {
                    id: npLoader
                    anchors.fill: visible ? parent : undefined
                    visible: PlayerState.view === 5
                    sourceComponent: NowPlaying { anchors.fill: parent
                                                 visible: PlayerState.view === 5
                                                 videoMenu: (sx, sy) => root.openVideoMenu(sx, sy, root) }
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
                mainWindow: true
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
    ClickThroughBadge {
        id: mainClickBadge
        // "title": in the title row, left of its buttons
        readonly property point titleSpot: {
            const r = mainTitle.buttonRow
            const p = mainTitle.mapToItem(root.contentItem, r.x, r.y + r.height / 2)
            return Qt.point(p.x - width - Theme.gap(6), p.y - height / 2)
        }
        x: Theme.lockPlace === "title" ? titleSpot.x
         : Theme.lockPlace === "left" ? Theme.gap(8)
         : Theme.lockPlace === "right" ? parent.width - width - Theme.gap(8)
         : (parent.width - width) / 2
        // on the title row's centre line, as its buttons are, but never above the window:
        // a pill is taller than a short title row; a tab hangs from the edge
        y: look === "tab" ? 0 : Math.max(0, titleSpot.y)
        z: 9000
        visible: root.clickThrough && !root.miniPlayer
        onXChanged: if (visible) root.updateMainInput()
        onYChanged: if (visible) root.updateMainInput()
        onReleased: root.clickThrough = false
    }
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

    // The theme's glass with nothing blurred behind it can be hard to read.
    // Off on offscreen and minimal, which have no compositor to blur.
    BlurNotice {
        id: blurNotice
        active: root.ready && Settings.loaded && !root.miniPlayer
                && Qt.platform.pluginName !== "offscreen" && Qt.platform.pluginName !== "minimal"
        wanted: Theme.glassBlur !== "off" && Theme.translucent("window")
        available: WindowCtl.blurAvailable
        suppressed: Settings.loaded && Settings.uiGet("blurNoticeOff", false) === true
        busy: promptDialog.visible
        onShowRequested: root.blurShown = true
        onDontShowAgain: Settings.uiSet("blurNoticeOff", true)
    }
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
        function onYtdlpStale(message) { root.ytdlpStale = message || "stale" }
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
            transientParent: root
            onImportPaths: (paths) => root.importAndEdit(paths)
            onUpdateNotesRequested: root.openUpdateNotes()
            onGuestReset: homeView.refresh()
            mainAreaRatio: (root.lastFullWidth * root.lastFullHeight) / 2073600
        }
    }
    function settingsWindow() { settingsLoader.active = true; return settingsLoader.item }
    Loader {
        id: eqLoader
        active: false
        sourceComponent: EqWindow { objectName: "eqWin"; transientParent: root }
    }
    function eqWindow() { eqLoader.active = true; return eqLoader.item }
    MetadataEditor { id: metadataEditor; onSettingsWanted: root.settingsWindow().open("general") }

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

    // a detached window's right click: its picture's entries, then the window's
    function openWindowMenu(w, sx, sy) { contextMenu.open(sx, sy, windowActs(w), w) }
    function windowActs(w) {
        const acts = w.kind === "video" ? videoActs() : []
        if (w.kind === "vis" && vizLoader.item)
            acts.push({ label: "Previous preset", act: () => vizLoader.item.backPreset() })
        if (w.kind !== "queue")
            acts.push({ label: "Overlay controls", check: w.overlay, rule: acts.length > 0,
                        act: () => w.setControls(w.overlay ? "bar" : "over") })
        if (root.miniPlayer)
            acts.push({ label: "Show mini player", check: !root.detachedHideBar, rule: w.kind === "queue" && acts.length > 0,
                        act: () => Settings.uiSet("detachedHideBar", !root.detachedHideBar) })
        if (root.pinToggles)
            acts.push({ label: "Keep above", check: w.keepAbove, rule: acts.length > 0,
                        act: () => w.setKeepAbove(!w.keepAbove) })
        if (root.miniPlayer && WindowCtl.canPlaceWindows)
            acts.push({ label: "Attach to mini player", rule: acts.length > 0, act: () => root.reattach(w) })
        acts.push({ label: "Close", rule: !root.miniPlayer && acts.length > 0, act: () => w.hide() })
        return acts
    }
    // the mini player's queue popup: the queue window's entries, for the popup
    function openPopupMenu(sx, sy) { contextMenu.open(sx, sy, popupActs(), root) }
    function popupActs() {
        const acts = []
        if (WindowCtl.canPlaceWindows)
            acts.push({ label: "Open in a window", act: () => root.detachFromPopup("queue", false) })
        if (root.pinToggles)
            acts.push({ label: "Keep melo above", check: root.alwaysOnTop, rule: acts.length > 0,
                        act: () => CommandMap.invoke("togglePin") })
        acts.push({ label: "Close", rule: acts.length > 0, act: () => CommandMap.invoke("toggleQueue") })
        return acts
    }
    // Quality and fit, on the picture itself. Flat, with a check on the
    // current value: the menu has no submenus of its own.
    function videoActs() {
        const q = Number(Settings.uiGet("videoQuality", 720))
        const f = String(Settings.uiGet("videoFit", "fill"))
        const acts = []
        for (const h of [360, 480, 720, 1080])
            acts.push({ label: h + "p", check: q === h, act: () => Settings.uiSet("videoQuality", h) })
        const fits = [["fill", "Fill"], ["fit", "Fit"], ["stretch", "Stretch"]]
        fits.forEach(([v, label], i) =>
            acts.push({ label: label, check: f === v, rule: i === 0, act: () => Settings.uiSet("videoFit", v) }))
        return acts
    }
    function openVideoMenu(sx, sy, host) { contextMenu.open(sx, sy, videoActs(), host) }

    // The player bar's own menu: the playing track's entries, then the bar's.
    // Through CommandMap, as the bar's buttons go, so a plugin's intercepts hold.
    function openBarMenu(sx, sy, host) {
        const acts = PlayerState.hasTrack && PlayerState.currentTrack
                   ? trackActs(PlayerState.currentTrack) : []
        const slot = root.miniPlayer ? "barMini" : root.barView === 5 ? "barNp" : "barMain"
        if (root.pinToggles)
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

    // A press anywhere outside the search field drops its focus, also when window
    // re-activation hands focus straight back to the TextInput. A passive handler:
    // a full-window MouseArea, even disabled, owns the cursor over everything under
    // it and would hide the resize and hand cursors.
    Item {
        anchors.fill: parent
        z: 940
        PointHandler {
            enabled: searchInput.activeFocus
            acceptedButtons: Qt.AllButtons
            onActiveChanged: if (active) {
                const p = parent.mapToItem(searchBarRect, point.position.x, point.position.y)
                if (!searchBarRect.contains(Qt.point(p.x, p.y)))
                    searchInput.focus = false
            }
        }
    }

    // A popup rather than a band across the top, so a stream failure also
    // shows in the compact window.
    // ---------- the error bars ----------
    // Every non-blocking error: the last failure melo raised (8 s, or a click),
    // the backend being down (a state: it stays), missing GStreamer elements,
    // the blur notice and the yt-dlp channel question. Above the player bar,
    // never on it; in the mini player, in a popup above the bar.
    property bool backendDown: false
    Timer {   // a sidecar that is merely starting does not flash the state
        interval: 500
        running: !sidecar.ready
        onTriggered: root.backendDown = true
    }
    Connections { target: sidecar; function onReadyChanged() { if (sidecar.ready) root.backendDown = false } }
    Timer {
        id: errorDismiss
        interval: 8000
        running: PlayerState.error.length > 0
        onTriggered: PlayerState.error = ""
    }
    Connections { target: PlayerState; function onErrorChanged() { if (PlayerState.error.length) errorDismiss.restart() } }
    property bool gstDismissed: false
    property bool blurShown: false
    property string ytdlpStale: ""
    // An AppImage's update. A tagged release opens its window by itself (once per
    // offer, when nothing else holds the screen) and the window carries the
    // download and Restart; a nightly has only the bar. A click on the bar's
    // offer is Later; on a failure it hides it until the next one.
    readonly property var updater: typeof Updater !== "undefined" ? Updater : null
    property string updateHidden: ""
    readonly property string updateKey: updater ? updater.state + ":" + updater.version + ":" + updater.errorKind : ""
    function updateNotice() {
        const u = root.updater
        if (!u || u.state === "" || root.updateHidden === root.updateKey) return null
        // a tagged release lives in its own window; a bar only for a failure while it is closed
        if (u.notes.length > 0) {
            if (u.state !== "failed" || root.updateWindowOpen) return null
            return { key: "update", message: u.error, actions: [{ id: "retry", label: "Try again" }] }
        }
        // a nightly has no notes: the bar is all there is
        const mb = 1024 * 1024
        if (u.state === "available")
            return { key: "update", message: u.version, alert: false,
                     actions: u.canUpdate ? [{ id: "update", label: "Update" }] : [] }
        if (u.state === "downloading")
            return { key: "update", message: "Downloading " + u.version + (u.total > 0
                         ? "  " + (u.fetched / mb).toFixed(1) + " / " + (u.total / mb).toFixed(1) + " MB" : ""),
                     alert: false, sticky: true, actions: [] }
        if (u.state === "ready")
            return { key: "update", message: u.version, alert: false, sticky: true,
                     actions: [{ id: "restart", label: "Restart" }] }
        return { key: "update", message: u.error, actions: [{ id: "retry", label: "Try again" }] }
    }
    readonly property var notices: {
        const out = []
        const report = { id: "report", label: "Report…" }
        const upd = root.updateNotice()
        if (upd) out.push(upd)
        if (root.backendDown && !sidecar.ready)
            out.push({ key: "backend", message: "melo's backend isn't running.",
                       actions: [report], sticky: true })
        if (MELO_MISSING_GST.length > 0 && !root.gstDismissed)
            out.push({ key: "gstreamer", sticky: true,
                       message: "Some GStreamer plugins are missing."
                                + (MELO_GST_HINT.length ? "" : " Install your distribution's GStreamer plugins."),
                       actions: (MELO_GST_HINT.length ? [{ id: "copy", label: "Copy install command" }] : [])
                                .concat([{ id: "ok", label: "OK" }]) })
        if (root.blurShown)
            out.push({ key: "blur", message: "Your desktop doesn't blur windows. This theme needs it.",
                       actions: [{ id: "theme", label: "Change theme" }, { id: "ok", label: "Not now" },
                                 { id: "never", label: "Don't show again" }], sticky: true })
        // while a track's failure is up, its dialog offers the switch instead; on nightly there is none
        if (root.ytdlpStale.length && !PlayerState.failCause && Settings.ytdlpChannel !== "nightly")
            out.push({ key: "ytdlp", message: "yt-dlp is out of date.",
                       actions: [{ id: "nightly", label: "Use yt-dlp nightly" }, { id: "no", label: "Not now" }], sticky: true })
        const c = root.errorContext
        if (PlayerState.error.length && c && c.text === PlayerState.error)
            out.push({ key: "error", message: c.text,
                       actions: (c.fix === "retry" && c.retry ? [{ id: "retry", label: "Try again" }]
                                 : c.fix === "settings" ? [{ id: "settings", label: "Open Settings" }] : [])
                                .concat(c.report ? [report] : []) })
        return out
    }
    function noticeAnswered(key, id) {
        if (key === "update") {
            const u = root.updater
            if (id === "update") u.update()
            else if (id === "restart") u.restart()
            else if (id === "retry") u.retry()
            return
        }
        if (key === "backend") { Report.send(Settings, "backend", "", { message: root.notices.find((n) => n.key === "backend").message }); return }
        if (key === "gstreamer") {
            if (id === "copy") { WindowCtl.copyToClipboard(MELO_GST_HINT); return }
            root.gstDismissed = true
            return
        }
        if (key === "blur") {
            root.blurShown = false
            blurNotice.dismiss(id === "never")
            if (id === "theme") root.settingsWindow().open("appearance")
            return
        }
        if (key === "ytdlp") {
            root.ytdlpStale = ""
            if (id === "nightly") sidecar.rpc("ytdlp/setChannel", { channel: "nightly" }, () => Settings.refresh())
            return
        }
        // the failure melo raised: its fix, or Report…
        const c = root.errorContext
        if (id === "report") { root.reportError(); return }
        PlayerState.error = ""
        if (!c) return
        if (id === "retry" && c.retry) c.retry()
        if (id === "settings") root.settingsWindow().open(c.tab || "general")
    }
    function noticeDismissed(key) {
        if (key === "error") PlayerState.error = ""
        if (key !== "update") return
        if (root.updater.state === "available") root.updater.later()
        else root.updateHidden = root.updateKey
    }
    Loader {
        id: updateNotesLoader
        active: false
        sourceComponent: UpdateNotesWindow { objectName: "updateNotesWin"; transientParent: root }
    }
    function openUpdateNotes() { updateNotesLoader.active = true; (updateNotesLoader.item as UpdateNotesWindow).open() }
    readonly property bool updateWindowOpen: updateNotesLoader.item !== null && (updateNotesLoader.item as UpdateNotesWindow).visible
    // an offer waiting for the screen: not over first-run setup or a dialog that asks
    property bool updatePending: false
    property string updateReadyShown: ""
    function updateScreenFree() {
        return root.ready && !onboarding.visible && !promptDialog.visible && !PlayerState.failCause
    }
    function tryOpenUpdate() {
        if (!root.updatePending || !root.updateScreenFree()) return
        root.updatePending = false
        if (root.updater && root.updater.notes.length > 0 && root.updater.state !== "") root.openUpdateNotes()
    }
    Timer { interval: 1000; repeat: true; running: root.updatePending; onTriggered: root.tryOpenUpdate() }
    Connections {
        target: root.updater
        function onOfferFound() {
            if (root.updater.notes.length === 0) return   // a nightly: the bar
            root.updatePending = true
            root.tryOpenUpdate()
        }
        // a download finished with its window closed: the window again, for Restart
        function onChanged() {
            const u = root.updater
            if (u.state !== "ready" || u.notes.length === 0 || root.updateWindowOpen
                    || root.updateReadyShown === u.version) return
            root.updateReadyShown = u.version
            root.updatePending = true
            root.tryOpenUpdate()
        }
    }
    QtObject { Component.onCompleted: Report.setShowFile((p) => WindowCtl.showFile(p)) }
    ErrorBarStack {
        id: noticeStack
        objectName: "noticeStack"
        z: 900
        visible: !root.miniPlayer && root.notices.length > 0
        notices: root.miniPlayer ? [] : root.notices
        maxWidth: Math.min(Theme.ctl(520), root.width - Theme.gap(24))
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        // above the player bar and the yt-dlp download toast, never on them
        anchors.bottomMargin: playerBar.settledHeight + root.barFoot + root.barRingTop + root.upperFoot
                              + Theme.gap(10) + (ytdlpToast.visible ? ytdlpToast.height + Theme.gap(8) : 0)
        onTriggered: (key, id) => root.noticeAnswered(key, id)
        onDismissed: (key) => root.noticeDismissed(key)
    }
    // the mini player's: a popup of its own above the bar, so it covers none of it
    Window {
        id: miniNotices
        objectName: "miniNotices"
        // X11 captions it, and the KWin scripts tell melo's windows apart by caption
        title: "melo-notices"
        flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
        color: "transparent"
        transientParent: miniWin
        visible: root.miniPlayer && miniWin.visible && root.notices.length > 0
        width: Math.min(Theme.ctl(520), Math.max(Theme.ctl(320), miniWin.width))
        height: Math.max(1, miniStack.implicitHeight)
        // window coords plus the bar's position (0,0 on Wayland, real on X11)
        x: miniWin.x + (miniWin.width - width) / 2
        y: miniWin.y - height - Theme.gap(6)
        ErrorBarStack {
            id: miniStack
            notices: root.miniPlayer ? root.notices : []
            maxWidth: miniNotices.width
            onTriggered: (key, id) => root.noticeAnswered(key, id)
            onDismissed: (key) => root.noticeDismissed(key)
        }
    }

    // The playing track could not be loaded: a dialog in the window in use,
    // picked when the failure arrives.
    property string failHost: ""
    function pickFailHost() {
        if (root.active && !root.miniPlayer) return "main"
        if (miniWin.active && root.miniPlayer) return "mini"
        for (const w of [queueWin, visWin, videoWin])
            if (w.open && w.active) return w.kind
        return root.miniPlayer ? "mini" : "main"
    }
    Connections {
        target: PlayerState
        function onFailureChanged() {
            root.failHost = PlayerState.failCause ? root.pickFailHost() : ""
            root.failBrowsers = []
            root.failChecking = false
        }
    }
    // "Use browser account": the browser signed in to YouTube, a choice when
    // several are (cookies/pickBrowser reads each installed one)
    property var failBrowsers: []
    property bool failChecking: false
    property int browserPickGen: 0
    function pickBrowser(done) {
        const gen = ++root.browserPickGen
        sidecar.rpc("cookies/pickBrowser", {}, (r) => {
            if (gen !== root.browserPickGen) return
            done(r && r.ok && r.result ? r.result : {})
        })
    }
    function playWithBrowser(b) {
        root.failBrowsers = []
        if (b && Settings.browser !== b) Settings.browser = b
        Player.answerFailure("browser")
    }
    function answerFailure(action) {
        if (action === "browser") {
            if (root.failChecking) return
            root.failChecking = true
            root.pickBrowser((res) => {
                root.failChecking = false
                if (PlayerState.failCause !== "guestWall") return
                if (res.choose && res.choose.length > 1) root.failBrowsers = res.choose
                else root.playWithBrowser(res.pick || Settings.browser)
            })
            return
        }
        if (action.indexOf("browser:") === 0) { root.playWithBrowser(action.slice(8)); return }
        // the dialog stays: its other answers still stand
        if (action === "report") {
            Report.send(Settings, "playback", PlayerState.failCause,
                        Object.assign({ message: PlayFail.messageFor(PlayerState.failCause, PlayerState.failReason,
                                                                     root.ytdlpStale.length > 0) },
                                      Player.lastFailure()))
            return
        }
        root.browserPickGen++   // an answer made while the check runs wins over it
        // a dialog that asked about yt-dlp: any answer is the answer to that too
        if (PlayerState.failCause !== "guestWall" && PlayerState.failCause !== "browserWall") root.ytdlpStale = ""
        Player.answerFailure(action)
    }
    // The bar's failure: `t` is errortext.js's answer, `details` what Report…
    // writes beside it (the backend's own line among them), `retry` the call
    // Try again makes. The same words again only restart its time.
    property var errorContext: null
    function showError(kind, sub, t, details, retry) {
        root.errorContext = { kind: kind, sub: sub, text: t.text, fix: t.fix, report: t.report,
                              tab: t.fix === "settings" ? "general" : "", details: details || {}, retry: retry || null }
        PlayerState.error = t.text
    }
    function reportError() {
        const c = root.errorContext
        if (c) Report.send(Settings, c.kind, c.sub, Object.assign({ message: c.text }, c.details))
    }
    Connections {
        target: Library
        function onDownloadFailed(videoId, error) {
            root.showError("download", "", ErrorText.download(error), { videoId: videoId, error: error },
                           () => Library.download(videoId))
        }
    }
    Connections {
        target: Player
        function onRadioFailed(reason) { root.showError("radio", "", ErrorText.radio(reason), { error: reason }) }
    }
    PlayFailDialog {
        id: playFailMain
        shown: root.failHost === "main"
        cause: PlayerState.failCause
        reason: PlayerState.failReason
        stale: root.ytdlpStale.length > 0
        choices: root.failBrowsers
        busy: root.failChecking
        onAnswered: (a) => root.answerFailure(a)
    }

    Rectangle {   // lite build: one-time Node.js runtime download
        visible: NodeSetup.active || NodeSetup.error.length > 0
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        z: 991
        MouseArea { anchors.fill: parent }   // modal
        // failed: the error dialog; nothing runs without Node.js
        ErrorPanel {
            objectName: "nodeError"
            visible: NodeSetup.error.length > 0
            blocking: true
            anchors.centerIn: parent
            width: Math.min(Theme.ctl(400), parent.width - Theme.gap(32))
            height: implicitHeight
            maxWidth: width
            message: "Node.js didn't download. Check your connection and try again."
            namePrefix: "node_"
            actions: [{ id: "retry", label: "Try again" }]
            onTriggered: (id) => NodeSetup.download()
        }
        Surface {
            visible: NodeSetup.active && NodeSetup.error.length === 0
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
                    text: "Downloading Node.js"
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
                    isPlaylist: true, videoCount: p.videoCount || 0,
                    kind: p.kind || "", year: p.year || 0, albumId: p.browseId || "" }))
                results = plRows.concat(results)
                root.fillSingles(playlists.filter((p) => p.kind === "Single" && p.browseId).map((p) => p.browseId))
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
            if (what !== "search") {
                const t = ErrorText.rpc(what)
                if (t) root.showError("error", what, t, { what: what, error: message })
                return
            }
            searchInput.searching = false
            root.searchFetchingMore = false
            if (root.searchFlow) {   // resolve the flow empty: single trim
                SkeletonModel.acceptBatch(searchResults, root.searchFlow, [], false)
                root.searchFlow = null
                root.flushPendingPluginRows()   // plugin rows that already arrived survive a YT failure
            }
            root.showError("search", "", ErrorText.search(message), { error: message }, () => {
                if (!root.lastQuery.length) return
                searchInput.text = root.lastQuery
                searchInput.accepted()
            })
        }
    }
    // Singles get their length from their album pages once they show; a one-track
    // single becomes its song, and that song's repeat further down goes
    function fillSingles(browseIds) {
        if (!browseIds.length) return
        sidecar.rpc("yt/singles", { browseIds: browseIds }, (r) => {
            const singles = r.ok && r.result ? (r.result.singles || []) : []
            for (const s of singles) {
                let at = -1
                for (let i = 0; i < searchResults.count && at < 0; i++) {
                    const m = searchResults.get(i)
                    if (m.isPlaylist && m.albumId === s.browseId) at = i
                }
                if (at < 0) continue   // a new search replaced the list
                if (!s.track) { searchResults.setProperty(at, "duration", s.duration); continue }
                const t = s.track
                for (let i = searchResults.count - 1; i > at; i--)
                    if (!searchResults.get(i).isPlaylist && searchResults.get(i).vid === t.id) searchResults.remove(i)
                searchResults.set(at, { vid: t.id, title: t.title, channel: t.channel || "", duration: t.duration || 0,
                                        thumbnail: t.thumbnail || searchResults.get(at).thumbnail, isPlaylist: false,
                                        videoCount: 0, album: t.album || "", year: t.year || searchResults.get(at).year,
                                        artists: Array.isArray(t.artists) ? t.artists.join("\n") : "" })
            }
        })
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
    function openPlaylistView(playlistId, title, initialTracks, album) {
        // a playlist opened from a playlist keeps the original origin
        if (PlayerState.view !== 3) root.playlistReturnView = PlayerState.view
        playlistView.open(playlistId, title, initialTracks || null, album || null)
        PlayerState.view = 3
    }

    function isSingle(album) { return !!(album && album.browseId && album.kind === "Single") }
    // a playlist's or album's tracks, first page; [] when it fails
    function listTracks(playlistId, album, cb) {
        const call = album && album.browseId ? ["yt/getAlbum", { browseId: album.browseId, playlistId: playlistId }]
                                             : ["yt/getPlaylistTracks", { playlistId: playlistId }]
        sidecar.rpc(call[0], call[1], (r) => {
            const ts = r.ok && r.result && r.result.ok ? (r.result.tracks || []) : []
            cb(ts.map((t) => Object.assign({}, t, { source: "youtube" })))
        })
    }
    // a single plays: one track as a song does, several queued from the first;
    // anything else, or a single whose page fails, opens in the playlist view
    function openPlaylistOrPlay(playlistId, title, album) {
        if (!root.isSingle(album)) {
            root.openPlaylistView(playlistId, title, null, album)
            return
        }
        root.listTracks(playlistId, album, (tracks) => {
            if (!tracks.length) root.openPlaylistView(playlistId, title, null, album)
            else if (tracks.length === 1) Player.playTrackData(tracks[0])
            else Player.playQueue(tracks, 0)
        })
    }
    // a playlist, album or single row's menu: what its click does not
    function openPlaylistMenu(playlistId, title, album, sx, sy) {
        const acts = []
        if (root.isSingle(album))
            acts.push({ label: "Open", act: () => root.openPlaylistView(playlistId, title, null, album) })
        else
            acts.push({ label: "Play", act: () => root.listTracks(playlistId, album, (ts) => { if (ts.length) Player.playQueue(ts, 0) }) })
        if (PlayerState.hasTrack) {
            acts.push({ label: "Add to next up", act: () => root.listTracks(playlistId, album, (ts) => { if (ts.length) Player.playNext(ts) }) })
            acts.push({ label: "Add to Queue", act: () => root.listTracks(playlistId, album, (ts) => { if (ts.length) Player.addToQueue(ts) }) })
        }
        acts.push({ label: "Copy link", act: () => WindowCtl.copyToClipboard(album && album.browseId
                        ? "https://music.youtube.com/browse/" + album.browseId
                        : "https://www.youtube.com/playlist?list=" + playlistId) })
        contextMenu.open(sx, sy, acts)
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
        CommandMap.setGesture("titleBar.doubleClick",
            bound("titleBar.doubleClick", "toggleMaximize"))
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
            // and re-syncs the shared popup; the full bar toggles the panel. Without
            // window placement there is no popup: the full player opens on the panel.
            case "toggleQueue":
                if (InterceptMap.offer("toggleQueue")) break
                if (root.miniPlayer && root.queueInWindow) {
                    root.toggleWindow("queue")
                } else if (root.miniPlayer) {
                    root.miniVisWanted = false
                    PlayerState.showPanel = !PlayerState.showPanel
                    root.syncMiniQueue()
                } else {
                    PlayerState.showPanel = !PlayerState.showPanel
                }
                break
            case "toggleVisualizer":
                if (InterceptMap.offer("toggleVisualizer")) break
                // full size has no popup: the button opens or closes the window
                if (!root.miniPlayer) {
                    if (visWin.open || videoWin.open) { if (visWin.open) visWin.hide(); if (videoWin.open) videoWin.hide() }
                    else root.toggleWindow(root.popupVideoMode ? "video" : "vis")
                    break
                }
                if (root.inWindow(root.popupVideoMode ? "video" : "vis")) {
                    root.toggleWindow(root.popupVideoMode ? "video" : "vis"); break
                }
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
            case "toggleClickThrough":
                root.clickThrough = !root.clickThrough
                break
            case "toggleQueueWindow":
                root.toggleWindow("queue")
                break
            case "toggleVisualizerWindow":
                root.toggleWindow("vis")
                break
            case "toggleVideoWindow":
                root.toggleWindow("video")
                break
            case "togglePin":
                if (InterceptMap.offer("togglePin")) break
                if (WindowCtl.pinMode === "menu") {
                    // runs inside the pin's press handler, so Qt's latest
                    // serial is that press. The mini bar has no pin, so the
                    // menu opens at its corner.
                    if (root.miniPlayer) {
                        WindowCtl.showWindowMenu(miniWin, 0, 0)
                    } else {
                        const p = mainTitle.pinPoint()
                        WindowCtl.showWindowMenu(root, p.x, p.y)
                    }
                    break
                }
                if (!root.pinToggles) break
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

    // ---------- frameless window resize ----------
    // freeze tick UI + hold the hover fade the instant OUR handle is pressed
    // A detached window's resize holds the same things still, and every other window in
    // the process on its last frame, application-wide (AppHold): KWin resizes cleanly only
    // while the rest of the process commits nothing. KWin's report of that window's new
    // place (onPopupWindow) ends it.
    property bool detachedResizing: false
    property var resizingWin: null
    function beginDetachedResize(w) {
        resizingWin = w
        w.resizing = true
        detachedResizing = true
        beginResizeHold()
        holdOthers(true)
    }
    function endDetachedResize() {
        detachedResizing = false
        if (resizingWin) resizingWin.resizing = false
        holdOthers(false)
        resizingWin = null
        sysDragging = false
        resizeFreeze = false
    }
    function holdOthers(on) {
        WindowCtl.holdAllBut(on ? resizingWin : null)
        applyMainHold()
    }
    function beginResizeHold() {
        sysDragging = true
        resizeFreeze = true          // carries the position freeze with it
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
        if (!resizeFreeze && detachedResizing) endDetachedResize()
        Player.setUiFrozen(resizeFreeze)
        Spectrum.setFrozen(resizeFreeze)
        if (PluginWindows) PluginWindows.setFrozen(resizeFreeze)
        resizeFreeze ? resizeFreezeSafety.restart() : resizeFreezeSafety.stop()
        applyMainHold()
    }
    // Through a bar resize main draws nothing, or with the popup open one frame after
    // each of the bar's: KWin stretches the bar's late frames, and main's popup frames
    // otherwise run on the thread that renders both windows, 3 to 11 inside each late one.
    readonly property bool mainLockstep: resizeFreeze && miniPlayer && miniQueueShown
    property bool mainWaits: true
    onMainLockstepChanged: { mainWaits = true; applyMainHold() }
    function applyMainHold() {
        WindowCtl.holdFrames(root, detachedResizing
                                   || (resizeFreeze && miniPlayer && (!miniQueueShown || mainWaits)))
    }
    function releaseMainFrame() {
        if (!mainWaits) return
        mainWaits = false
        mainFrameDue.stop()
        applyMainHold()
    }
    Connections {
        target: root.mainLockstep ? miniWin : null
        function onFrameSwapped() { root.releaseMainFrame() }
    }
    Connections {
        target: root.mainLockstep ? root : null
        function onFrameSwapped() {
            root.mainWaits = true
            root.applyMainHold()
            mainFrameDue.restart()
        }
    }
    // a bar that draws nothing new (a corner moved straight up) leaves main its turn
    Timer { id: mainFrameDue; interval: 34; onTriggered: root.releaseMainFrame() }
    // Last resort only. The real releases are KWin's ended report and,
    // without KWin, the hover fallback above; this is a floor so a missed
    // signal cannot leave plugin windows permanently unable to redraw.
    Timer {
        id: resizeFreezeSafety
        interval: 30000
        onTriggered: root.resizeFreeze = false
    }
    // KWin's finished report clears sysDragging; hover resuming clears it
    // too (non-KDE fallback) — release the tick freeze on either path
    onSysDraggingChanged: if (!sysDragging) {
        // Without KWin there is no "ENDED" REPORT, so the hover heuristic that
        // clears sysDragging is the only signal a drag finished. With KWin it
        // is a guess, and a wrong one mid-resize — which is why the freeze does
        // not take it there.
        if (!kwinSwap) resizeFreeze = false
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
            // a square corner faces one way but at its point: the edge within 14 px
            // of a corner drags the corner, as the tool windows' corners do
            if (e) {
                const c = 14
                if (x < c) e = (e & ~Qt.RightEdge) | Qt.LeftEdge
                else if (x > width - c) e = (e & ~Qt.LeftEdge) | Qt.RightEdge
                if (y < c) e = (e & ~Qt.BottomEdge) | Qt.TopEdge
                else if (y > height - c) e = (e & ~Qt.TopEdge) | Qt.BottomEdge
            }
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
