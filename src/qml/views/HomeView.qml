import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import QtQuick.Effects
import Qt5Compat.GraphicalEffects
import ".."
import "../components"
import "../components/skeletonmodel.js" as SkeletonModel
import "../components/homeempty.js" as HomeEmpty

// Home: YouTube source = topic chips + recommended feed
// with continuations; YouTube Music source = mood chips + shelves of
// playlists, albums and songs, the next shelves loaded as the page scrolls.
Item {
    id: view
    property var contextMenu: null
    property var trackMenu: null
    property string layout: "list"
    signal changeLayout(string mode)
    signal openPlaylist(string playlistId, string title)

    readonly property bool ytMusic: Settings.homeSource !== "youtube"

    // YTM section cards share the rec-grid tile geometry (same column
    // math, same reserve, same scaled text block) — they ARE tiles
    readonly property int ytAvailW: width - GridUi.padX
    readonly property int ytCols: GridUi.colsFor(ytAvailW, GridUi.growth)
    readonly property real ytCellW: GridUi.cellWFor(ytAvailW, GridUi.growth)

    // In-place chip model: placeholders morph into the real chips (delegates
    // persist across the swap, so width/color animate instead of jumping)
    ListModel { id: chipModel }
    readonly property var chipPhW: [42, 60, 56, 50, 72, 48, 64, 78, 58, 96, 84]   // real-chip-ish spread
    function resetChipPlaceholders() {
        chipModel.clear()
        topUpChipPlaceholders()
    }
    // placeholder chips across the whole bar, and more of them when it widens
    // while they are still up
    function topUpChipPlaceholders() {
        let used = 0
        for (let i = 0; i < chipModel.count; i++) {
            if (chipModel.get(i).placeholder !== true) return
            used += chipModel.get(i).phW + chipRow.spacing
        }
        const want = Math.max(chipBar.width, 1)
        while (used < want || chipModel.count < chipPhW.length) {
            const w = chipPhW[chipModel.count % chipPhW.length]
            chipModel.append({ text: "", token: "", isSelected: false, placeholder: true, phW: w })
            used += w + chipRow.spacing
        }
    }
    function applyChips(cs) {
        for (let i = 0; i < cs.length; i++) {
            const c = { text: cs[i].text, token: cs[i].token,
                        isSelected: cs[i].isSelected === true, placeholder: false, phW: 0 }
            if (i < chipModel.count) chipModel.set(i, c)
            else chipModel.append(c)
        }
        while (chipModel.count > cs.length) chipModel.remove(chipModel.count - 1)
    }
    property string activeChipToken: ""
    property var sections: []
    property bool loadingMain: false
    property bool loadingChip: false
    property bool loadingMore: false
    property string continuation: ""
    property string homeError: ""
    property bool loadedOnce: false
    // cookies/status: whether the CURRENT identity is actually signed in.
    // Only a signed-in session gets an empty home out of a paused watch
    // history, so nothing else is allowed to claim that cause.
    property bool signedIn: false
    function refreshAuth() {
        if (!sidecar.ready) return
        sidecar.rpc("cookies/status", {}, (r) => {
            view.signedIn = !!(r.ok && r.result && r.result.signedIn)
        })
    }

    ListModel { id: recModel }

    // One empty state for both sources, outside either source's view, so an
    // empty YouTube feed shows it too.
    readonly property int contentCount: ytMusic ? sections.length : recModel.count
    readonly property var emptyNow: HomeEmpty.emptyState({
        loadedOnce: view.loadedOnce,
        loading: view.loadingMain || view.loadingChip || view.loadingMore,
        error: view.homeError,
        count: view.contentCount,
        cookieSource: Settings.cookieSource,
        sendPlayback: Settings.sendPlayback,
        signedIn: view.signedIn,
    })

    function fmtDur(s) {
        if (!s) return ""
        const m = Math.floor(s / 60)
        return m + ":" + (Math.floor(s % 60) < 10 ? "0" : "") + Math.floor(s % 60)
    }

    // priority order: All, Music, Mixes, then the rest
    function orderChips(cs) {
        const priority = ["all", "music", "mixes"]
        const buckets = [null, null, null], rest = []
        for (const c of cs) {
            const i = priority.indexOf(c.text.toLowerCase())
            if (i !== -1) buckets[i] = c
            else rest.push(c)
        }
        return buckets.filter(Boolean).concat(rest)
    }

    // Batches route through the load-flow state machine while placeholders
    // remain (they get consumed in place; leftovers trigger the next page);
    // once resolved, plain appends with the view's add-transition take over.
    property var flow: null
    function handleBatch(arr, cont) {
        continuation = cont || ""
        const hasMore = continuation.length > 0
        if (flow) {
            const wantMore = SkeletonModel.acceptBatch(recModel, flow, arr, hasMore)
            if (wantMore) { Qt.callLater(fetchNextPage) }
            else flow = null
        } else {
            for (const t of arr)
                recModel.append({ placeholder: false, vid: t.id, title: t.title,
                                  channel: t.channel || "", duration: t.duration || 0,
                                  thumbnail: t.thumbnail || "" })
        }
    }
    function fetchNextPage() {
        if (!continuation.length || loadingMore) return
        loadingMore = true
        sidecar.rpc("yt/recommendedContinuation", { token: continuation }, (r) => {
            loadingMore = false
            if (r.ok && r.result) handleBatch(r.result.tracks || [], r.result.continuation)
            else { continuation = ""; if (flow) { SkeletonModel.acceptBatch(recModel, flow, [], false); flow = null } }
        })
    }

    // placeholders needed to fill THIS view's viewport in the current layout
    // (shared math: grid counts always complete their rows)
    function placeholderCount() {
        return SkeletonModel.fillCount(layout, width, height, GridUi.growth)
    }

    // enough placeholder shelves to fill the page, each a full row of cards
    // (or a handful of rows in list and compact)
    function placeholderSections() {
        const cards = []
        const perShelf = layout === "grid" ? Math.max(1, ytCols) : 4
        for (let i = 0; i < perShelf; i++)
            cards.push({ kind: "playlist", playlistId: "", videoId: "", title: "", description: "",
                         channel: "", thumbnail: "", placeholder: true })
        const shelfH = layout === "grid" ? GridUi.cellHFor(ytCellW) + 40
                     : perShelf * Theme.sp(layout === "compact" ? 26 : 54) + 40
        const n = Math.max(2, Math.ceil(Math.max(height, 1) / shelfH))
        const out = []
        for (let i = 0; i < n; i++) out.push({ title: "", placeholder: true, items: cards })
        return out
    }
    function sectionsArePlaceholders() {
        return sections.length > 0 && sections[0].placeholder === true
    }

    // A resize can open space the load never planned for. The skeletons are
    // counted for the window as it was when the load began, and the check for
    // another page otherwise runs only on scroll and on a batch landing, so
    // growing the window (full screen) would leave the new space blank.
    function viewportChanged() {
        if (!loadedOnce) return
        if (chipModel.count > 0) topUpChipPlaceholders()
        if (ytMusic) {
            if (loadingMain && sectionsArePlaceholders()) {
                const next = placeholderSections()
                if (next.length !== sections.length || next[0].items.length !== sections[0].items.length)
                    sections = next
            }
            ytmMaybeMore()
            return
        }
        topUpSkeletons()
        maybeFillViewport()
    }
    // more placeholders while a load's are still unfilled; the flow consumes
    // them like its own and asks for another page for any the batch leaves
    function topUpSkeletons() {
        if (!flow) return
        if (!loadingMain && !loadingChip) return   // a pagination tail fills its own row
        let want = placeholderCount()
        if (layout === "grid" && recGrid.cols > 0) want = Math.ceil(want / recGrid.cols) * recGrid.cols
        if (want > recModel.count) SkeletonModel.addBlanks(recModel, want - recModel.count)
    }

    function refresh() {
        if (!sidecar.ready) return
        loadedOnce = true
        loadingMain = true
        refreshAuth()
        homeError = ""; activeChipToken = ""; continuation = ""
        resetChipPlaceholders()
        sections = []
        flow = SkeletonModel.beginLoad(recModel, placeholderCount())
        if (ytMusic) {
            loadMusicHome("")
        } else {
            sidecar.rpc("yt/getRecommended", { count: 30 }, (r) => {
                if (!r.ok || !r.result) {
                    loadingMain = false
                    homeError = r.error || "Failed to load recommendations"
                    // Take the skeletons down with it. The placeholders were
                    // seeded before the call; left up, the error draws over a
                    // grid of loading cards that will never fill. The chip
                    // path trims them the same way.
                    if (flow) { SkeletonModel.acceptBatch(recModel, flow, [], false); flow = null }
                    else recModel.clear()
                    return
                }
                const ordered = orderChips(r.result.chips || [])
                view.applyChips(ordered)
                // auto-select the Music chip when present. The loading state
                // must stay up UNBROKEN until the chip content arrives:
                // flipping loadingMain off before loadingChip on shows one
                // empty frame between the two skeleton phases.
                const music = ordered.find((c) => c.text.toLowerCase() === "music")
                if (music && music.token) {
                    view.activeChipToken = music.token
                    loadChip(music.token)
                } else {
                    handleBatch(r.result.tracks || [], "")
                    loadingMain = false
                }
            })
        }
    }

    // ---------- YouTube Music ----------
    // The whole home, not its first page: YouTube Music sends two or three shelves
    // and a continuation token, and the rest loads on scroll. A mood chip opens that
    // mood's home. Songs and albums show alongside playlists.
    property string ytmContinuation: ""
    function musicChips(cs) {
        return (cs || []).map((c) => ({ text: c.text, token: c.params, isSelected: c.isSelected === true }))
    }
    function loadMusicHome(params) {
        loadingMain = true
        ytmContinuation = ""
        sections = placeholderSections()
        sidecar.rpc("yt/getHome", params ? { params: params } : {}, (r) => {
            loadingMain = false
            if (r.ok && r.result && r.result.sections) {
                view.sections = r.result.sections
                view.ytmContinuation = r.result.continuation || ""
                // the plain home's chips stay while a mood's home is open
                if (!params) view.applyChips(view.musicChips(r.result.chips))
                Qt.callLater(view.ytmMaybeMore)
            } else {
                view.sections = []
                if (!params) view.applyChips([])
                homeError = r.error || "Failed to load home"
            }
        })
    }
    function ytmMore() {
        if (!ytmContinuation.length || loadingMore) return
        loadingMore = true
        const token = ytmContinuation
        sidecar.rpc("yt/homeContinuation", { token: token }, (r) => {
            loadingMore = false
            if (token !== view.ytmContinuation) return   // a chip or a refresh replaced the page
            if (r.ok && r.result) {
                view.sections = view.sections.concat(r.result.sections || [])
                view.ytmContinuation = r.result.continuation || ""
                Qt.callLater(view.ytmMaybeMore)
            } else view.ytmContinuation = ""
        })
    }
    // more while the page does not fill the view or the end is near
    function ytmMaybeMore() {
        if (!ytMusic || !ytmContinuation.length) return
        const f = ytmFlick
        if (f.contentHeight <= f.height + 200 || f.contentY + f.height >= f.contentHeight - 600) ytmMore()
    }
    function kindLabel(kind) {
        return ({ playlist: "Playlist", album: "Album", artist: "Artist", song: "Song" })[kind] || ""
    }
    // a playlist, an album (as its playlist) or an artist (as its radio) opens
    // in the playlist view; a song plays, as a YouTube track does
    function homeItemClick(it) {
        if (it.kind === "song") view.tileClick(view.homeSongTile(it))
        else view.openPlaylist(it.playlistId, it.title)
    }
    function homeSongTile(it) {
        return { vid: it.videoId, title: it.title, channel: it.channel, duration: 0, thumbnail: it.thumbnail }
    }

    function loadChip(token) {
        loadingChip = true
        continuation = ""
        sidecar.rpc("yt/getRecommendedByChip", { token: token }, (r) => {
            if (r.ok && r.result) {
                handleBatch(r.result.tracks || [], r.result.continuation)
                if (r.result.chips && r.result.chips.length) view.applyChips(orderChips(r.result.chips))
            } else if (flow) {
                SkeletonModel.acceptBatch(recModel, flow, [], false)
                flow = null
            }
            loadingChip = false
            loadingMain = false
        })
    }

    function chipClick(chip) {
        if (ytMusic) {
            if (loadingMain || chip.placeholder === true) return
            activeChipToken = chip.token === activeChipToken ? "" : chip.token
            loadMusicHome(activeChipToken)
            return
        }
        if (loadingChip || chip.placeholder === true) return
        if (chip.isSelected && activeChipToken === "") return
        flow = SkeletonModel.beginLoad(recModel, placeholderCount())   // morph when the chip loads
        if (chip.isSelected) {   // "All": back to the plain feed
            activeChipToken = ""
            loadingChip = true
            continuation = ""
            sidecar.rpc("yt/getRecommended", { count: 30 }, (r) => {
                loadingChip = false
                if (r.ok && r.result) handleBatch(r.result.tracks || [], "")
                else if (flow) { SkeletonModel.acceptBatch(recModel, flow, [], false); flow = null }
            })
        } else {
            activeChipToken = chip.token
            loadChip(chip.token)
        }
    }

    // pagination tail: complete the grid's partial row + one full row
    // (small by design — batches always over-fill it, so no trims)
    function paginationTail() {
        return SkeletonModel.paginationTail(layout, width, recModel.count, GridUi.growth, recGrid.cols)
    }
    function loadMore() {
        if (flow) return   // the flow drives its own follow-up fetches
        if (loadingMain || loadingChip || loadingMore) return
        if (!continuation.length) return
        // staged: the partial row now, the full row on the next turn — see
        // SkeletonModel.beginAppend
        const tail = paginationTail()
        flow = SkeletonModel.beginAppend(recModel, tail, SkeletonModel.paginationChunk(tail))
        if (flow.rest > 0) tailStage.enabled = true
        fetchNextPage()
    }
    // The second stage lands on the next frameSwapped, so the first chunk is on
    // screen first. Not a timer (a guess at frame rate), and not idle: these fill
    // space being scrolled into.
    Connections {
        id: tailStage
        enabled: false
        // through the view, not on the Connections: the Window attached
        // property only resolves on an Item
        target: view.Window.window
        function onFrameSwapped() {
            tailStage.enabled = false
            if (!view.flow || view.flow.rest <= 0) return
            SkeletonModel.addBlanks(recModel, view.flow.rest)
            view.flow.rest = 0
        }
    }

    function maybeFillViewport() {
        if (loadingMain || loadingChip || loadingMore || flow) return
        const v = view.layout === "grid" ? recGrid : recList
        if (v.count === 0) return
        // short content OR parked at/near the end when a batch lands —
        // atYEnd doesn't re-FIRE if it never went false, so pagination
        // would stall for anyone sitting at the bottom
        if ((v.contentHeight > 0 && v.contentHeight <= v.height) || v.atYEnd) loadMore()
    }
    // a load that ends without a page after it (its batch over-filled the
    // skeletons) checks too, or a window grown during it is never filled
    onLoadingMoreChanged: if (!loadingMore) Qt.callLater(maybeFillViewport)
    onLoadingMainChanged: if (!loadingMain) Qt.callLater(maybeFillViewport)
    onLoadingChipChanged: if (!loadingChip) Qt.callLater(maybeFillViewport)

    function tileTrack(m) {
        return { id: m.vid, title: m.title, channel: m.channel,
                 duration: m.duration, thumbnail: m.thumbnail }
    }
    function tileClick(m) {
        if (m.vid.startsWith("RD")) view.openPlaylist(m.vid, m.title)
        else Player.playTrackData(view.tileTrack(m))
    }
    function tileMenu(m, sx, sy) {
        if (!m.vid.startsWith("RD")) {
            if (view.trackMenu) view.trackMenu(view.tileTrack(m), sx, sy)
            return
        }
        // a mix is not a track: it has no library, no metadata and nothing to
        // queue until it is opened, so it gets its own short menu
        if (!view.contextMenu) return
        view.contextMenu.open(sx, sy, [
            { label: "Open", act: () => view.openPlaylist(m.vid, m.title) },
            { label: "Play", act: () => Player.startRadioPlaylist(m.vid) },
            { label: "Copy link", act: () => WindowCtl.copyToClipboard(
                        "https://www.youtube.com/playlist?list=" + m.vid) },
        ])
    }

    // First load waits for BOTH the sidecar AND the settings: the saved
    // layout arrives with the settings, and seeding skeletons before it is
    // known renders them in the wrong layout. Deferred a tick so the
    // settings handlers (which set the layout) run first.
    function maybeFirstLoad() {
        if (loadedOnce) return
        if (sidecar.ready && Settings.loaded) { Qt.callLater(refresh); return }
        if (Settings.loaded) Qt.callLater(seedWarmup)
    }
    // Skeletons before the sidecar is up. refresh() returns at the top until
    // the sidecar is ready, which on a cold profile is ten seconds of PO-token
    // prewarm and yt-dlp download; without this the page is blank meanwhile.
    // beginLoad reseeds, so refresh() doing it again later is not a second set.
    function seedWarmup() {
        if (loadedOnce || !Settings.loaded) return
        if (width <= 0 || height <= 0) return
        if (recModel.count > 0 || sections.length > 0) return
        if (ytMusic) sections = placeholderSections()
        else flow = SkeletonModel.beginLoad(recModel, placeholderCount())
    }
    onWidthChanged: { if (!loadedOnce) seedWarmup(); Qt.callLater(viewportChanged) }
    onHeightChanged: Qt.callLater(viewportChanged)
    onLayoutChanged: Qt.callLater(viewportChanged)
    Connections {
        target: sidecar
        function onReadyChanged() { view.maybeFirstLoad() }
    }
    Connections {
        target: Settings
        function onLoadedChanged() { view.maybeFirstLoad() }
    }
    onYtMusicChanged: if (loadedOnce) refresh()
    // An identity switch reloads the feed: chips and recommendations belong to the
    // session. Settings has one `changed` for every key, so the switch is detected
    // by value.
    readonly property string identity:
        Settings.cookieSource + "\u0000" + Settings.cookieProfile + "\u0000" + Settings.browser
    // Deferred a turn: SettingsStore::patch emits `changed` before sending
    // settings/set, so an inline refresh puts yt/getRecommended on the wire first and
    // gets the old identity's feed. After callLater, settings/set is queued first and
    // the sidecar answers in order.
    onIdentityChanged: if (loadedOnce) Qt.callLater(refresh)
    Component.onCompleted: maybeFirstLoad()

    // ---------- toolbar: refresh + chip bar + layout toggle ----------
    Item {
        id: toolbar
        objectName: "pageHeader"
        // The chips follow the list's column. The heading block is measured from the
        // page's own edge, not plus the page inset (both name the same edge). The list
        // and grid below clear its bottom.
        readonly property int availW: Math.max(0, parent.width - Theme.inset("pageHeader", "left")
                                                              - Theme.inset("pageHeader", "right"))
        readonly property int colW: view.layout === "grid" ? availW : GridUi.listW(availW)
        y: Theme.inset("pageHeader", "top")
        x: Theme.inset("pageHeader", "left") + Math.round((availW - colW) / 2)
        width: colW
        height: 40

        PushButton {   // refresh
            id: refreshBtn
            anchors.verticalCenter: parent.verticalCenter
            // a round one, never taller than it is wide
            width: Math.max(Theme.ctl(28), height); radius: Theme.pill(height / 2)
            label: "↻"; fontSize: 12
            onClicked: view.refresh()
        }

        Flickable {   // chip bar: horizontal drag-scroll with momentum
            id: chipBar
            anchors.left: refreshBtn.right
            anchors.leftMargin: Theme.gap(8)
            anchors.right: layoutTgl.left
            anchors.rightMargin: Theme.gap(8)
            anchors.verticalCenter: parent.verticalCenter
            height: 26
            visible: chipModel.count > 0
            contentWidth: chipRow.width
            flickableDirection: Flickable.HorizontalFlick
            clip: true

            readonly property bool fadeLeft: contentX > 2
            readonly property bool fadeRight: contentX < contentWidth - width - 2
            layer.enabled: fadeLeft || fadeRight
            // OpacityMask, not MultiEffect: MultiEffect's mask is an alpha threshold (at
            // maskThresholdMin 0 nothing is cut), while OpacityMask multiplies by alpha.
            layer.effect: OpacityMask { maskSource: chipMask }
            SegmentTrack { strip: chipRow; style: Theme.chips }
            Row {
                id: chipRow
                spacing: Theme.chips === "segment" ? 0 : Theme.gap(6)
                Repeater {
                    model: chipModel
                    SelectTab {
                        id: chipItem
                        required property int index
                        required property string text
                        required property string token
                        required property bool isSelected
                        required property bool placeholder
                        required property int phW
                        style: Theme.chips
                        label: text
                        active: !placeholder && (view.activeChipToken === ""
                            ? isSelected : token === view.activeChipToken)
                        hover: chMa.containsMouse; pressed: chMa.pressed
                        blank: placeholder
                        fontSize: 11
                        width: placeholder ? phW : implicitWidth
                        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        height: 26
                        textOpacity: placeholder ? 0 : 1
                        Behavior on textOpacity { NumberAnimation { duration: 180 } }
                        Skeleton {
                            anchors.fill: parent; radius: chipItem.radius
                            opacity: chipItem.placeholder ? 1 : 0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: 180 } }
                        }
                        MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: view.chipClick({ text: chipItem.text, token: chipItem.token,
                                                                isSelected: chipItem.isSelected,
                                                                placeholder: chipItem.placeholder }) }
                    }
                }
            }
        }

        // The chips fade their own alpha; a translucent Theme.window over them would
        // tint, not hide. A plain Rectangle: MultiEffect makes the texture itself, and a
        // layer of its own left nothing to sample. Stops bind through the id because
        // `parent` inside a Gradient is the Gradient, which gave NaN.
        Rectangle {
            id: chipMask
            width: chipBar.width
            height: chipBar.height
            visible: false
            // A long linear ramp dims a wide band of chips instead of ending
            // them: short, and weighted so most of the alpha is gone in the
            // first few pixels.
            readonly property real edge: Math.min(0.09, 12 / Math.max(1, width))
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0
                               color: chipBar.fadeLeft ? "#00ffffff" : "#ffffffff" }
                GradientStop { position: chipMask.edge * 0.45
                               color: chipBar.fadeLeft ? "#a0ffffff" : "#ffffffff" }
                GradientStop { position: chipMask.edge; color: "#ffffffff" }
                GradientStop { position: 1 - chipMask.edge; color: "#ffffffff" }
                GradientStop { position: 1 - chipMask.edge * 0.45
                               color: chipBar.fadeRight ? "#a0ffffff" : "#ffffffff" }
                GradientStop { position: 1.0
                               color: chipBar.fadeRight ? "#00ffffff" : "#ffffffff" }
            }
        }

        LayoutToggle {
            id: layoutTgl
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            layout: view.layout
            onChanged_: (mode) => view.changeLayout(mode)
        }
    }

    // An error draws in `danger`, the role that means wrong; `highlight`
    // follows `accent` and means a thing is active or current. The size
    // matches the empty-state line beside it.
    InkText {
        anchors.centerIn: parent
        visible: view.homeError.length > 0
        width: parent.width - 60
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: view.homeError
        ink: "danger"
        font { pixelSize: Theme.fs(15); family: Theme.fontFamily }
    }

    // ---------- YouTube: recommended list / compact ----------
    ListView {
        id: recList
        QQC.ScrollBar.vertical: MScrollBar {}
        anchors.top: toolbar.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.bottomMargin: GridUi.padBottom
        // held to a column and centred; the view carries the wheel handler
        width: GridUi.listW(Math.max(0, parent.width - GridUi.padX))
        x: Math.round((parent.width - width) / 2)
        visible: !view.ytMusic && view.layout !== "grid"
        model: recModel
        clip: true
        spacing: Theme.gap(2)
        onAtYEndChanged: if (atYEnd && count > 0) view.loadMore()   // loadMore guards loading states
        // prefetch EARLY: spawn the skeleton tail while approaching the end
        // instead of only at the hard stop (atYEnd alone also stalled when
        // it never re-fired — loadMore guards make retriggers free)
        readonly property bool nearEnd:
            contentHeight > height && contentY + height >= contentHeight - height
        onNearEndChanged: if (nearEnd && count > 0) view.loadMore()
        onCountChanged: Qt.callLater(view.maybeFillViewport)
        onHeightChanged: Qt.callLater(view.maybeFillViewport)
        // Pooled, because a resize or scroll releases delegates and each rebuilt one
        // rebuilds its fill chain (15ms of polish a frame on a bevelled theme vs 1ms
        // pooled). Each delegate's onReused resets what the remove transition left.
        reuseItems: true
        cacheBuffer: 400
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150 } }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 } }

        readonly property bool compact: view.layout === "compact"

        delegate: Surface {
            // A pooled delegate keeps what the remove transition left on it: that
            // transition fades opacity to 0, the item is pooled still at 0, and a
            // reused item is not an added one — so the add transition never runs
            // and the card comes back invisible, text and all.
            ListView.onReused: opacity = 1
            id: rrow
            required property int index
            required property var model
            width: Math.max(0, recList.width - Theme.scrollGutter)
            height: Theme.sp(recList.compact ? 26 : GridUi.rowH(width))
            radius: Theme.radiusMd
            role: rma.containsMouse ? "hover" : ""

            Row {
                anchors.fill: parent
                // The inset is the list row's padding; the compact row trims it,
                // never past the edge.
                anchors.topMargin: Theme.rowInset("top", recList.compact ? 3 : 0)
                anchors.bottomMargin: Theme.rowInset("bottom", recList.compact ? 3 : 0)
                anchors.leftMargin: Theme.inset("row", "left") + (recList.compact ? 2 : 0)
                // a right-aligned value needs more air than a filled block
                anchors.rightMargin: Theme.rowInset("right", recList.compact ? 8 : 0)
                spacing: recList.compact ? 8 : 10

                Skeleton {
                    visible: !recList.compact
                    width: GridUi.rowThumbW(parent.width)
                    height: Math.round(width * 9 / 16); radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    shimmer: rrow.model.placeholder === true
                    Image { anchors.fill: parent
                            // see MediaTile: not fetched while the page is hidden, and
                            // kept once it has been shown
                            property bool everShown: false
                            onVisibleChanged: if (visible) everShown = true
                            Component.onCompleted: if (visible) everShown = true
                            source: !(visible || everShown) ? "" : GridUi.art(rrow.model.thumbnail)
                            fillMode: Image.PreserveAspectCrop; asynchronous: true
                            // Pinned, never the item's width: a live width re-decodes and
                            // blanks on every drag step. 180 is a quarter of a ~720px
                            // source, which libjpeg scales during decode.
                            sourceSize.width: GridUi.rowPx
                            opacity: status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 150 } } }
                }
                Column {
                    visible: !recList.compact
                    width: Math.max(0, parent.width - GridUi.rowThumbW(parent.width)
                                 - 10 - recDur.width - 10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(2)
                    SkeletonText { width: parent.width; text: rrow.model.title; ink: "text"
                                   hoverSource: rma
                                   loading: rrow.model.placeholder === true
                                   placeholderWidth: Theme.sp(180 + ((rrow.index * 53) % 260)); barHeight: 13
                                   font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily } }
                    SkeletonText { width: parent.width
                                   text: rrow.model.channel
                                         + (rrow.model.views ? " · " + rrow.model.views : "")
                                         + (rrow.model.age ? " · " + rrow.model.age : "")
                                   ink: "textDim"
                                   hoverSource: rma
                                   loading: rrow.model.placeholder === true
                                   placeholderWidth: Theme.sp(160 + ((rrow.index * 29) % 60)); barHeight: 11
                                   font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                }
                SkeletonValue {   // duration: morphs like the title/channel bars
                    id: recDur
                    visible: !recList.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(Theme.sp(34), textW)
                    alignRight: true
                    text: rrow.model.placeholder === true ? "" : view.fmtDur(rrow.model.duration)
                    loading: rrow.model.placeholder === true
                    placeholderWidth: 30; barHeight: 11
                    color: Theme.textSoft
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }

                SkeletonText {
                    id: hcTitle
                    visible: recList.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth,
                           Math.max(80, parent.width - parent.spacing - hcMeta.implicitWidth)))
                    text: rrow.model.title; ink: "text"
                    hoverSource: rma
                    loading: rrow.model.placeholder === true
                    // container width is invisible and already final when the
                    // morph measures (one tick after the flip) — safe to morph
                    placeholderWidth: Theme.sp(170 + ((rrow.index * 37) % 200)); barHeight: 13
                    font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily }
                }
                SkeletonText {
                    id: hcMeta
                    // second inline bar: the artist/duration morphs alongside
                    // the title, like the thumbnail rows' stacked pair
                    visible: recList.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - parent.spacing - hcTitle.width)
                    text: rrow.model.channel
                          + (rrow.model.duration > 0 ? " · " + view.fmtDur(rrow.model.duration) : "")
                    ink: "textDim"
                    hoverSource: rma
                    loading: rrow.model.placeholder === true
                    placeholderWidth: Theme.sp(70 + ((rrow.index * 29) % 60)); barHeight: 11
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }

            MouseArea {
                id: rma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (m) => {
                    if (rrow.model.placeholder === true) return
                    const p = rma.mapToItem(null, m.x, m.y)
                    if (m.button === Qt.RightButton) view.tileMenu(rrow.model, p.x, p.y)
                    else view.tileClick(rrow.model)
                }
            }
        }
    }

    // ---------- YouTube: recommended grid ----------
    GridView {
        id: recGrid

        QQC.ScrollBar.vertical: MScrollBar {}
        // When originY moves, hold the top only if the view is AT the top;
        // anywhere else contentY is left alone, so what is on screen does not
        // move. `atTop` comes from contentY because the wheel sets contentY
        // directly and never starts a movement.
        property bool atTop: true
        onContentYChanged: atTop = contentY <= originY + 1
        function toTop() {
            if (!visible || moving || dragging) return
            if (atTop || contentY < originY) contentY = originY
        }
        onVisibleChanged: toTop()
        onOriginYChanged: toTop()
        onContentHeightChanged: toTop()
        anchors.top: toolbar.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.bottom: parent.bottom
        anchors.bottomMargin: GridUi.padBottom
        // left-pinned, not centred — see LibraryView's grid (centring shimmied
        // the whole grid by ±cols/2 px per resize step)
        anchors.left: parent.left
        anchors.leftMargin: GridUi.padLeft
        readonly property int availW: parent.width - GridUi.padX - Theme.scrollGutter
        readonly property int cols: GridUi.colsFor(availW, GridUi.growth)
        cellWidth: GridUi.cellWFor(availW, GridUi.growth)
        readonly property int slack: GridUi.slackOf(availW, cols, cellWidth)
        // the whole box, not cols * cellWidth: the slack is handed out per
        // column below, so an exact-fit width would only move the right edge
        width: availW + Theme.scrollGutter
        visible: !view.ytMusic && view.layout === "grid"
        model: recModel
        clip: true
        onAtYEndChanged: if (atYEnd && count > 0) view.loadMore()   // loadMore guards loading states
        // prefetch EARLY: spawn the skeleton tail while approaching the end
        // instead of only at the hard stop (atYEnd alone also stalled when
        // it never re-fired — loadMore guards make retriggers free)
        readonly property bool nearEnd:
            contentHeight > height && contentY + height >= contentHeight - height
        onNearEndChanged: if (nearEnd && count > 0) view.loadMore()
        onCountChanged: Qt.callLater(view.maybeFillViewport)
        onHeightChanged: { toTop(); Qt.callLater(view.maybeFillViewport) }
        reuseItems: true
        cacheBuffer: 400
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150 } }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 } }

        // text block is a fixed 144px design transform-scaled with the tile
        // (see tscale in the delegate) — reserve its SCALED height
        cellHeight: GridUi.cellHFor(cellWidth)

        delegate: Item {
            // A pooled delegate keeps what the remove transition left on it: that
            // transition fades opacity to 0, the item is pooled still at 0, and a
            // reused item is not an added one — so the add transition never runs
            // and the card comes back invisible, text and all.
            GridView.onReused: { rcell.pooled = false; opacity = 1 }
            // A pooled item's bindings still fire, so tracking the cell size walked every
            // pooled tile per resize step (+17% drag cost once scrolled). Pooling drops the
            // binding; reuse restores it.
            GridView.onPooled: rcell.pooled = true
            id: rcell
            property bool pooled: false
            required property int index
            required property var model
            // GUARDED like the two below, and for the same reason: it reads
            // the grid's slack, so an unguarded binding would walk the whole
            // pool on every step of a drag.
            property real slackX: 0
            Binding on slackX { when: !rcell.pooled
                                value: GridUi.slackX(rcell.index % recGrid.cols, recGrid.slack)
                                restoreMode: Binding.RestoreNone }
            Binding on width { when: !rcell.pooled; value: recGrid.cellWidth
                               restoreMode: Binding.RestoreNone }
            Binding on height { when: !rcell.pooled; value: recGrid.cellHeight
                                restoreMode: Binding.RestoreNone }

            MediaTile {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap(4); anchors.rightMargin: Theme.gap(4)
                anchors.bottomMargin: Theme.gap(8)
                // The floor's leftover pixels, one per column in the gap (GridUi.slackX). A
                // Translate, not margins: margins relaid the tile every drag step (120 frames over
                // 33ms became 440); a transform only changes the node's matrix.
                transform: Translate { x: rcell.slackX }
                title_: rcell.model.title
                meta_: rcell.model.channel
                art: rcell.model.thumbnail || ""
                duration: rcell.model.duration || 0
                loading: rcell.model.placeholder === true
                tipTitle: true
                onClicked_: view.tileClick(rcell.model)
                onMenu: (sx, sy) => view.tileMenu(rcell.model, sx, sy)
            }
        }
    }

    // ---------- YouTube Music: mix sections ----------
    Flickable {
        id: ytmFlick
        QQC.ScrollBar.vertical: MScrollBar {}
        anchors.top: toolbar.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: GridUi.padBottom
        anchors.leftMargin: GridUi.padLeft; anchors.rightMargin: GridUi.padRight
        visible: view.ytMusic
        contentHeight: ytmCol.implicitHeight + 20
        onContentYChanged: view.ytmMaybeMore()
        clip: true

        Column {
            id: ytmCol
            width: parent.width - Theme.scrollGutter
            spacing: Theme.gap(8)

            Repeater {
                model: view.sections
                Column {
                    id: secCol
                    required property var modelData
                    readonly property bool secPh: modelData.placeholder === true
                    // a shelf of songs (Quick picks) is a list, not cards
                    readonly property bool songShelf: !secPh && modelData.items.length > 0
                                                      && modelData.items.every((i) => i.kind === "song")
                    width: view.layout === "grid" ? ytmCol.width : GridUi.listW(ytmCol.width)
                    x: Math.round((ytmCol.width - width) / 2)
                    spacing: Theme.gap(6)

                    SkeletonText { width: parent.width; text: parent.secPh ? "" : modelData.title
                                   ink: "text"
                                   loading: parent.secPh
                                   placeholderWidth: 180; barHeight: 15
                                   font { pixelSize: Theme.fs(15); weight: Theme.weightBold; family: Theme.fontFamily } }
                    InkText { visible: !parent.secPh
                           text: "YouTube Music"; ink: "textFaint"
                           font { pixelSize: Theme.fs(10); family: Theme.fontFamily } }

                    // Songs are rows in every layout, several abreast on the grid
                    // as YouTube Music lays Quick picks; in list and compact every
                    // shelf is rows, as the YouTube feed's are
                    Grid {
                        id: songGrid
                        readonly property bool rows: secCol.songShelf || view.layout !== "grid"
                        readonly property bool compact: view.layout === "compact"
                        visible: rows
                        width: parent.width
                        columns: view.layout === "grid" ? Math.max(1, Math.floor(width / Theme.ctl(300))) : 1
                        columnSpacing: Theme.gap(8)
                        rowSpacing: Theme.gap(2)
                        Repeater {
                            model: songGrid.rows ? secCol.modelData.items : []
                            Surface {
                                id: sRow
                                required property var modelData
                                required property int index
                                readonly property bool ph: modelData.placeholder === true
                                readonly property bool song: modelData.kind === "song"
                                width: (songGrid.width - (songGrid.columns - 1) * songGrid.columnSpacing) / songGrid.columns
                                height: songGrid.compact ? Theme.sp(26)
                                      : song ? Theme.ctl(48) : Theme.sp(GridUi.rowH(width))
                                radius: Theme.radiusMd
                                role: !ph && sMa.containsMouse ? "hover" : ""
                                readonly property string sub: song ? modelData.channel
                                                              : (modelData.description || view.kindLabel(modelData.kind))
                                Skeleton {
                                    id: sArt
                                    visible: !songGrid.compact
                                    x: Theme.gap(4)
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: sRow.song ? parent.height - Theme.gap(8) : Math.round(width * 9 / 16)
                                    width: sRow.song ? height : GridUi.rowThumbW(parent.width)
                                    radius: Theme.radiusSm
                                    shimmer: sRow.ph
                                    Image { anchors.fill: parent
                                            source: sRow.ph ? "" : GridUi.art(sRow.modelData.thumbnail)
                                            fillMode: Image.PreserveAspectCrop; asynchronous: true
                                            sourceSize.width: sRow.song ? 96 : GridUi.rowPx
                                            opacity: status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 150 } } }
                                }
                                Column {
                                    visible: !songGrid.compact
                                    anchors.left: sArt.right; anchors.leftMargin: Theme.gap(8)
                                    anchors.right: parent.right; anchors.rightMargin: Theme.gap(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    SkeletonText { width: parent.width
                                                   text: sRow.ph ? "" : sRow.modelData.title; ink: "text"
                                                   hoverSource: sMa; loading: sRow.ph
                                                   placeholderWidth: Theme.sp(160 + ((sRow.index * 53) % 200)); barHeight: 12
                                                   font { pixelSize: Theme.fs(12); weight: Theme.weightMedium; family: Theme.fontFamily } }
                                    SkeletonText { width: parent.width
                                                   text: sRow.ph ? "" : sRow.sub; ink: "textDim"
                                                   hoverSource: sMa; loading: sRow.ph
                                                   placeholderWidth: Theme.sp(90 + ((sRow.index * 29) % 60)); barHeight: 10
                                                   font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                                }
                                Row {
                                    visible: songGrid.compact
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.inset("row", "left") + 2
                                    anchors.rightMargin: Theme.rowInset("right", 8)
                                    spacing: 8
                                    SkeletonText {
                                        id: sTitle
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.max(0, Math.min(implicitWidth,
                                               Math.max(80, parent.width - parent.spacing - sMeta.implicitWidth)))
                                        text: sRow.ph ? "" : sRow.modelData.title; ink: "text"
                                        hoverSource: sMa; loading: sRow.ph
                                        placeholderWidth: Theme.sp(170 + ((sRow.index * 37) % 200)); barHeight: 13
                                        font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily } }
                                    SkeletonText {
                                        id: sMeta
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.max(0, parent.width - parent.spacing - sTitle.width)
                                        text: sRow.ph ? "" : sRow.sub; ink: "textDim"
                                        hoverSource: sMa; loading: sRow.ph
                                        placeholderWidth: Theme.sp(70 + ((sRow.index * 29) % 60)); barHeight: 11
                                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                                }
                                MouseArea {
                                    id: sMa; anchors.fill: parent; hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (m) => {
                                        if (sRow.ph) return
                                        if (m.button !== Qt.RightButton) { view.homeItemClick(sRow.modelData); return }
                                        if (!sRow.song) return
                                        const p = sMa.mapToItem(null, m.x, m.y)
                                        view.tileMenu(view.homeSongTile(sRow.modelData), p.x, p.y)
                                    }
                                }
                            }
                        }
                    }
                    Flow {
                        visible: !songGrid.rows
                        width: parent.width
                        spacing: Theme.gap(8)
                        Repeater {
                            model: songGrid.rows ? [] : secCol.modelData.items
                            Surface {
                                id: pCard
                                required property var modelData
                                readonly property bool ph: modelData.placeholder === true
                                width: view.ytCellW - 8
                                height: GridUi.cellHFor(width + 8)
                                radius: Theme.radiusLg
                                role: !ph && pMa.containsMouse ? "hover" : "card"
                                clip: true
                                readonly property real unit: width / 160
                                function ins(name, side) { return (Theme.ts, Theme.cardInset(name, side) * unit) }
                                readonly property real artIn: ins("cardArt", "left")
                                Skeleton {
                                    id: pThumb
                                    x: pCard.ins("cardArt", "left")
                                    y: pCard.ins("cardArt", "top")
                                    width: parent.width - x - pCard.ins("cardArt", "right")
                                    height: GridUi.dev(width * 9 / 16)
                                    radius: Theme.cardArtCorners === "square" ? 0 : Theme.cardArtCorners === "round" ? Theme.radiusLg
                                          : pCard.artIn > 0 ? Theme.radiusSm : Theme.radiusLg
                                    bottomRadius: pCard.artIn > 0 ? radius : 0
                                    shimmer: pCard.ph
                                    Image { anchors.fill: parent
                                            // see MediaTile: not fetched while the page is hidden, and
                                            // kept once it has been shown
                                            property bool everShown: false
                                            onVisibleChanged: if (visible) everShown = true
                                            Component.onCompleted: if (visible) everShown = true
                                            source: !(visible || everShown) ? "" : GridUi.art(pCard.modelData.thumbnail)
                                            fillMode: Image.PreserveAspectCrop; asynchronous: true
                                            sourceSize.width: GridUi.rowPx
                                            opacity: status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 150 } } }
                                }
                                // same fixed-design scaled text block as the rec grid
                                Item {
                                    readonly property real tscale: parent.width / 160
                                    x: pCard.ins("cardText", "left")
                                    anchors.top: pThumb.bottom
                                    anchors.topMargin: pCard.ins("cardText", "top")
                                    width: (pCard.width - x - pCard.ins("cardText", "right")) / tscale
                                    height: Math.max(20, (pCard.height - pThumb.y - pThumb.height - anchors.topMargin - pCard.ins("cardText", "bottom")) / tscale)
                                    scale: tscale
                                    transformOrigin: Item.TopLeft
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: 3
                                        width: parent.width
                                        spacing: 1
                                        SkeletonText { width: parent.width
                                                       text: pCard.ph ? "" : pCard.modelData.title
                                                       ink: "text"
                                                       loading: pCard.ph
                                                       tip: true; hoverSource: pMa; maxLines: 2; lineHeight: 0.95
                                                       morph: false; placeholderWidth: 108; barHeight: 9; barOffset: -1
                                                       font { pixelSize: Theme.fs(10); weight: Theme.weightMedium; family: Theme.fontFamily } }
                                        SkeletonText { width: parent.width
                                                       text: pCard.ph ? "" : (pCard.modelData.description || view.kindLabel(pCard.modelData.kind))
                                                       ink: "textDim"
                                                       loading: pCard.ph
                                                       morph: false; placeholderWidth: 72; barHeight: 8
                                                       font { pixelSize: Theme.fs(9); family: Theme.fontFamily } }
                                    }
                                }
                                MouseArea {
                                    id: pMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        if (pCard.ph) return
                                        view.homeItemClick(pCard.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    Column {
        anchors.centerIn: parent
        spacing: Theme.gap(14)
        visible: view.emptyNow !== null
        InkText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: view.emptyNow ? view.emptyNow.line : ""
            ink: "textDim"
            font { pixelSize: Theme.fs(15); family: Theme.fontFamily }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.gap(8)
            visible: !!(view.emptyNow && view.emptyNow.actions)
            PushButton {
                label: "Open history settings"
                accent: true
                onClicked: Qt.openUrlExternally("https://myaccount.google.com/activitycontrols")
            }
            PushButton {
                label: "Use a guest profile"
                onClicked: Settings.cookieSource = "guest"
            }
        }
    }

    // ONE handler, on the view rather than inside a list: a handler that
    // fills a column-width list only takes the wheel while the pointer is
    // over the rows, and the margin beside them is most of a wide window.
    WheelScroll { parent: view; target: view.ytMusic ? ytmFlick : (view.layout === "grid" ? recGrid : recList) }

}
