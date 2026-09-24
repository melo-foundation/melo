import QtQuick
import QtQuick.Controls as QQC
import ".."
import "../components"
import "../components/skeletonmodel.js" as SkeletonModel

// Playlist page: back + title + Save [& Download] /
// Sync header, indexed track rows in the shared layouts. Row click: RD mixes
// start radio at that index; normal playlists queue from that index.
Item {
    id: view
    property var contextMenu: null
    property var trackMenu: null
    property string layout: "list"
    signal changeLayout(string mode)
    signal back()

    property string playlistId
    property string playlistTitle
    property bool loading: false
    property bool syncing: false
    property string plError

    // hasPlaylist is a plain call, so a binding on it re-runs only on
    // playlistId, and the library arrives later over RPC. Re-derive on both.
    property bool inLibrary: false
    function refreshInLibrary() { inLibrary = Library.hasPlaylist(playlistId) }
    onPlaylistIdChanged: refreshInLibrary()
    Connections {
        target: Library
        function onCountsChanged() { view.refreshInLibrary() }
    }
    // an album is assembled from library metadata, not fetched: there is
    // nothing to save, sync, or take a track out of
    readonly property bool albumList: playlistId.startsWith("album:")
    readonly property bool canSync: inLibrary && !albumList && !playlistId.startsWith("local-")

    // Upper bound on rows an id can return, or 0 when unknown. Seeded mixes
    // (RDAMVM<videoId>, RD<videoId>) come from one watch-next page (~20 rows); curated
    // mixes and playlists return everything. Mirrors MIX_FIRST_PAGE in
    // sidecar/src/streams.ts; keep in step.
    function expectedMax(id) {
        if (!id || !id.startsWith("RD")) return 0
        if (/^RD(AMPL|CLAK|GM|EM|TM)/.test(id)) return 0   // seedless: panel/playlist
        const seed = id.startsWith("RDAMVM") ? id.slice(6)
                   : id.startsWith("RDMM")   ? id.slice(4)
                                             : id.slice(2)
        return seed.length === 11 ? 20 : 0   // only a real video seed caps at one page
    }

    // placeholders needed to fill THIS view's viewport in the current layout
    // (shared math: grid counts always complete their rows), capped by what the
    // source can actually produce — seeding 40 rows for a 20-row mix means the
    // surplus fades out on arrival, which reads as the list collapsing.
    function placeholderCount() {
        const fill = SkeletonModel.fillCount(layout, width, height, GridUi.growth)
        const max = expectedMax(playlistId)
        return max > 0 ? Math.min(fill, max) : fill
    }

    ListModel { id: plModel }

    // Removals must leave the open list too, as nothing here listens for library
    // changes. A playlist that is not yours cannot be edited, so X hides the row: the
    // id is remembered per playlist and filtered from every load (and the queue).
    // The Settings guard lets tests load this view alone.
    readonly property bool hasSettings: typeof Settings !== "undefined"
    function hiddenIds() {
        if (!hasSettings) return []
        const all = Settings.uiGet("hiddenTracks", {}) || {}
        return all[playlistId] || []
    }
    function hideTrack(vid) {
        if (!hasSettings) return
        const all = Settings.uiGet("hiddenTracks", {}) || {}
        const ids = (all[playlistId] || []).slice()
        if (ids.indexOf(vid) === -1) ids.push(vid)
        all[playlistId] = ids
        Settings.uiSet("hiddenTracks", all)
        dropTrack(vid)
    }
    function shown(tracks) {
        const h = hiddenIds()
        if (!h.length) return tracks || []
        return (tracks || []).filter((t) => h.indexOf(t.id) === -1)
    }
    function dropTrack(vid) {
        for (let i = 0; i < plModel.count; i++) {
            if (plModel.get(i).vid === vid) { plModel.remove(i); return }
        }
    }

    function fmtDur(s) {
        if (!s) return ""
        const m = Math.floor(s / 60)
        return m + ":" + (Math.floor(s % 60) < 10 ? "0" : "") + Math.floor(s % 60)
    }
    function rowTrack(m) {
        return { id: m.vid, title: m.title, channel: m.channel,
                 duration: m.duration, thumbnail: m.thumbnail }
    }
    function allTracks() {
        const out = []
        for (let i = 0; i < plModel.count; i++) {
            const m = plModel.get(i)
            if (m.placeholder !== true) out.push(rowTrack(m))
        }
        return out
    }

    // wall-clock of the click, so the log measures what the USER waits for
    // (RPC + model fill + first layout), not just the sidecar's own timing
    property double openedAt: 0
    property int seededCount: 0
    property string listCursor: ""     // "" = source exhausted, no more pages
    property bool fetchingMore: false
    property var moreFlow: null

    function open(id, title, initialTracks) {
        openedAt = Date.now()
        listCursor = ""
        fetchingMore = false
        moreFlow = null
        const changed = id !== playlistId
        playlistId = id
        console.log("[playlist-ui] open id=" + id + " inLibrary=" + view.inLibrary
                    + " layout=" + view.layout)
        playlistTitle = title || ""
        plError = ""
        // Clear the previous playlist's rows first. apply() fills placeholders in place
        // so skeletons morph, but reused across a navigation the old rows and thumbnails
        // flash until each new one decodes.
        if (changed) {
            plModel.clear()
            // A ListView/GridView that is not visible defers its layout, so the
            // previous playlist's delegates survive into the first visible
            // frame even though the model is already empty — that is the flash.
            // Forcing the relayout while still hidden retires them first.
            list.forceLayout()
            grid.forceLayout()
            list.positionViewAtBeginning()
            grid.positionViewAtBeginning()
        }
        if (initialTracks && initialTracks.length > 0) {
            SkeletonModel.apply(plModel, view.shown(initialTracks))
            loading = false
            console.log("[list-ui] " + id + " source=caller tracks=" + plModel.count
                        + " skeletons=0 in " + (Date.now() - openedAt) + "ms")
            return
        }
        loading = true
        seededCount = placeholderCount()
        SkeletonModel.seed(plModel, seededCount)   // placeholders morph in place
        sidecar.rpc("yt/getPlaylistTracks", { playlistId: id }, (r) => {
            if (view.playlistId !== id) return
            loading = false
            if (r.ok && r.result && r.result.ok) {
                const n = (r.result.tracks || []).length
                view.listCursor = r.result.cursor || ""
                SkeletonModel.apply(plModel, view.shown(r.result.tracks))
                // seeded > n means the surplus placeholders fade out on arrival;
                // seeded < n means rows append below the fold with no morph
                console.log("[list-ui] " + id + " tracks=" + n
                            + " skeletons=" + view.seededCount
                            + (view.seededCount > n ? " (trimmed " + (view.seededCount - n) + ")"
                             : view.seededCount < n ? " (appended " + (n - view.seededCount) + ")" : " (exact)")
                            + " layout=" + view.layout
                            + " in " + (Date.now() - view.openedAt) + "ms")
                if (r.result.title && !view.playlistTitle.length)
                    view.playlistTitle = r.result.title
            } else {
                plModel.clear()
                plError = (r.result && r.result.error) || r.error || "Failed to load playlist"
            }
        })
    }

    // Scroll pagination. Same shape as HomeView/SearchView: append a tail of
    // placeholders so the delegates exist and morph in place when rows land.
    function loadMore() {
        if (fetchingMore || loading || !listCursor.length) return
        fetchingMore = true
        moreFlow = SkeletonModel.beginAppend(plModel, SkeletonModel.paginationTail(
            layout, width, plModel.count, GridUi.growth))
        const forId = playlistId
        const t0 = Date.now()
        sidecar.rpc("yt/getPlaylistMore", { cursor: listCursor, count: 40 }, (r) => {
            if (view.playlistId !== forId) return   // navigated away mid-flight
            view.fetchingMore = false
            if (!r.ok || !r.result || !r.result.ok) {
                // expired/failed: drop the tail placeholders rather than leave
                // them shimmering forever
                SkeletonModel.acceptBatch(plModel, view.moreFlow, [], false)
                view.listCursor = ""
                return
            }
            const rows = r.result.tracks || []
            view.listCursor = r.result.cursor || ""
            SkeletonModel.acceptBatch(plModel, view.moreFlow, rows, false)
            console.log("[list-ui] " + forId + " +" + rows.length + " rows total=" + plModel.count
                        + " more=" + (view.listCursor.length ? "yes" : "no")
                        + " in " + (Date.now() - t0) + "ms")
        })
    }

    // atYEnd only fires on a CHANGE, so a reader already parked at the bottom
    // never triggers another page, and content shorter than the viewport never
    // scrolls at all. Same guard HomeView/SearchView carry.
    function maybeFillViewport() {
        if (loading || fetchingMore || !listCursor.length) return
        const v = layout === "grid" ? grid : list
        if (v.count === 0) return
        if ((v.contentHeight > 0 && v.contentHeight <= v.height) || v.atYEnd) loadMore()
    }
    onFetchingMoreChanged: if (!fetchingMore) Qt.callLater(maybeFillViewport)
    onLoadingChanged: if (!loading) Qt.callLater(maybeFillViewport)

    function playAt(index) {
        if (loading) return
        // Both branches queue the rows currently on screen; mixes also arm
        // radio autoplay. Re-fetching a mix returns ~20 rows and clamps the
        // index into them, so a click deep in a paged mix would play an
        // unrelated track.
        if (playlistId.startsWith("RD")) Player.playMixAt(allTracks(), index, playlistId, listCursor)
        else Player.playQueue(allTracks(), index)
    }

    function saveToLibrary(download) {
        const ts = allTracks()
        if (!ts.length) return
        const thumb = ts[0].thumbnail || ""
        sidecar.rpc("library/addPlaylist",
            { playlistId: playlistId, title: playlistTitle, thumbnail: thumb, tracks: ts },
            (r) => {
                if (download && r.ok) Library.downloadAll(ts.map((t) => t.id))
            })
    }

    function sync() {
        if (syncing) return
        syncing = true
        const meta = Library.playlistMeta(playlistId)
        sidecar.rpc("yt/getPlaylistTracks", { playlistId: playlistId }, (r) => {
            if (r.ok && r.result && r.result.ok) {
                SkeletonModel.apply(plModel, view.shown(r.result.tracks))
                sidecar.rpc("library/addPlaylist",
                    { playlistId: view.playlistId, title: meta.title || view.playlistTitle,
                      thumbnail: meta.thumbnail || "", tracks: view.allTracks() },
                    () => { view.syncing = false })
            } else {
                view.syncing = false
                view.plError = (r.result && r.result.error) || "Sync failed"
            }
        })
    }

    // ---------- header ----------
    Item {
        id: header
        objectName: "pageHeader"
        // Measured from the page's own edge, not the page inset: the two name
        // the same visible edge, so adding them moves the block twice. It
        // follows the content column, as Home's does.
        readonly property int availW: Math.max(0, parent.width - Theme.inset("pageHeader", "left")
                                                              - Theme.inset("pageHeader", "right"))
        readonly property int colW: view.layout === "grid" ? availW : GridUi.listW(availW)
        y: Theme.inset("pageHeader", "top")
        x: Theme.inset("pageHeader", "left") + Math.round((availW - colW) / 2)
        width: colW
        height: 40

        InkText {
            id: backBtn
            anchors.verticalCenter: parent.verticalCenter
            text: "← Back"
            ink: backMa.containsMouse ? "text" : "textDim"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
            MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: view.back() }
        }
        ScrollText {
            anchors.left: backBtn.right
            anchors.leftMargin: Theme.gap(12)
            anchors.right: actions.left
            anchors.rightMargin: Theme.gap(12)
            anchors.verticalCenter: parent.verticalCenter
            text: view.playlistTitle
            ink: "text"
            font { pixelSize: Theme.fs(14); weight: Theme.weightBold; family: Theme.fontFamily }
        }
        Row {
            id: actions
            anchors.right: layoutTgl.left
            anchors.rightMargin: Theme.gap(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.gap(6)
            PushButton { visible: !view.inLibrary && !view.albumList && !view.loading && plModel.count > 0
                         label: "Save"; onClicked: view.saveToLibrary(false) }
            PushButton { visible: !view.inLibrary && !view.albumList && !view.loading && plModel.count > 0
                         label: "Save + Download"; onClicked: view.saveToLibrary(true) }
            PushButton { visible: view.canSync
                         // a sync already running: the button says so and takes nothing
                         enabled: !view.syncing
                         label: view.syncing ? "Syncing…" : "Sync"
                         onClicked: view.sync() }
        }
        LayoutToggle {
            id: layoutTgl
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            layout: view.layout
            onChanged_: (mode) => view.changeLayout(mode)
        }
    }

    InkText {
        anchors.centerIn: parent
        visible: view.plError.length > 0
        text: view.plError
        ink: "highlight"
        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
    }

    // ---------- list / compact ----------
    ListView {
        id: list
        QQC.ScrollBar.vertical: MScrollBar {}
        // The header sits at negative content y (originY = -headerHeight), so the top
        // is originY, not 0. When originY moves, hold the top only if already at the top;
        // otherwise leave contentY alone. `atTop` derives from contentY because the wheel
        // sets it directly without starting a movement.
        property bool atTop: true
        onContentYChanged: atTop = contentY <= originY + 1
        function toTop() {
            if (!visible || moving || dragging) return
            if (atTop || contentY < originY) contentY = originY
        }
        onVisibleChanged: toTop()
        onOriginYChanged: toTop()
        onContentHeightChanged: toTop()
        anchors.top: header.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.bottom: parent.bottom
        anchors.bottomMargin: GridUi.padBottom
        // held to a column and centred; the view carries the wheel handler
        width: GridUi.listW(Math.max(0, parent.width - GridUi.padX))
        x: Math.round((parent.width - width) / 2)
        visible: view.layout !== "grid"
        model: plModel
        clip: true
        spacing: Theme.gap(2)
        reuseItems: true
        cacheBuffer: 400
        onAtYEndChanged: if (atYEnd && count > 0) view.loadMore()
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150 } }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 } }

        readonly property bool compact: view.layout === "compact"

        delegate: Surface {
            // A pooled delegate keeps what the remove transition left on it: that
            // transition fades opacity to 0, the item is pooled still at 0, and a
            // reused item is not an added one — so the add transition never runs
            // and the card comes back invisible, text and all.
            ListView.onReused: opacity = 1
            id: row
            required property int index
            required property var model
            readonly property bool active: PlayerState.hasTrack
                                           && PlayerState.currentTrack.id === model.vid
            width: Math.max(0, list.width - Theme.scrollGutter)
            height: Theme.sp(list.compact ? 26 : GridUi.rowH(width))
            radius: Theme.radiusMd
            role: active ? "selected" : ma.containsMouse ? "hover" : ""

            Row {
                anchors.fill: parent
                // The inset is the list row's padding; the compact row trims it by
                // what it always sat tighter by, and never past the edge.
                anchors.topMargin: Theme.rowInset("top", list.compact ? 3 : 0)
                anchors.bottomMargin: Theme.rowInset("bottom", list.compact ? 3 : 0)
                anchors.leftMargin: Theme.inset("row", "left") + (list.compact ? 2 : 0)
                // a right-aligned value needs more air than a filled block
                anchors.rightMargin: Theme.rowInset("right", list.compact ? 8 : 0)
                spacing: list.compact ? 8 : 10

                InkText {   // index: known from the row position, never loaded —
                         // skeletoning it only hid information we already have
                    width: Math.max(Theme.sp(20), implicitWidth)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: row.index + 1
                    ink: row.active ? "highlight" : "textFaint"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                Skeleton {
                    visible: !list.compact
                    width: GridUi.rowThumbW(parent.width)
                    height: Math.round(width * 9 / 16); radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    shimmer: row.model.placeholder === true
                    Image { anchors.fill: parent
                            // see MediaTile: not fetched while the page is hidden, and
                            // kept once it has been shown
                            property bool everShown: false
                            onVisibleChanged: if (visible) everShown = true
                            Component.onCompleted: if (visible) everShown = true
                            source: !(visible || everShown) ? "" : GridUi.art(row.model.thumbnail)
                            fillMode: Image.PreserveAspectCrop; asynchronous: true
                            sourceSize.width: GridUi.rowPx
                            opacity: status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 150 } } }
                }
                Column {
                    visible: !list.compact
                    width: Math.max(0, parent.width - 22 - 10 - 64 - 10 - plDur.width - 10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(2)
                    SkeletonText { width: parent.width; text: row.model.title; ink: "text"
                                   hoverSource: ma
                                   loading: row.model.placeholder === true
                                   placeholderWidth: Theme.sp(180 + ((row.index * 53) % 260)); barHeight: 13
                                   font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily } }
                    SkeletonText { width: parent.width
                                   // views and age arrive with every row
                                   text: row.model.channel
                                         + (row.model.views ? " · " + row.model.views : "")
                                         + (row.model.age ? " · " + row.model.age : "")
                                   ink: "textDim"
                                   hoverSource: ma
                                   loading: row.model.placeholder === true
                                   placeholderWidth: Theme.sp(160 + ((row.index * 29) % 60)); barHeight: 11
                                   font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                }
                SkeletonValue {   // duration: morphs like the title/channel bars
                    id: plDur
                    visible: !list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(Theme.sp(34), textW)
                    alignRight: true
                    text: row.model.placeholder === true ? "" : view.fmtDur(row.model.duration)
                    loading: row.model.placeholder === true
                    placeholderWidth: 30; barHeight: 11
                    color: Theme.textSoft
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }

                SkeletonText {
                    id: pcTitle
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth,
                           Math.max(80, parent.width - 22 - parent.spacing * 2 - pcMeta.implicitWidth)))
                    text: row.model.title; ink: "text"
                    hoverSource: ma
                    loading: row.model.placeholder === true
                    // container width is invisible and already final when the
                    // morph measures (one tick after the flip) — safe to morph,
                    // same as HomeView's hcTitle
                    placeholderWidth: Theme.sp(170 + ((row.index * 37) % 200)); barHeight: 13
                    font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily }
                }
                SkeletonText {
                    id: pcMeta
                    // second inline bar, morphing alongside the title (as HomeView's compact rows).
                    // Both must morph, or the title's width snaps while the meta's x follows.
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - 22 - parent.spacing * 2 - pcTitle.width)
                    text: row.model.channel
                          + (row.model.duration > 0 ? " · " + view.fmtDur(row.model.duration) : "")
                    ink: "textDim"
                    hoverSource: ma
                    loading: row.model.placeholder === true
                    // varied like hcMeta: a constant width made every row's
                    // title resolve to the same size in lockstep
                    placeholderWidth: Theme.sp(70 + ((row.index * 29) % 60)); barHeight: 11
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }

            // Remove from a saved playlist, or hide from one that is not yours.
            // Sits above `ma` so the click does not fall through and play the
            // track.
            Surface {
                id: rmBtn
                // rmMa takes the hover off `ma` the moment the pointer
                // reaches the button, so the row's hover alone would hide it
                // exactly when it is aimed at
                visible: row.model.placeholder !== true && !view.albumList
                         && (ma.containsMouse || rmMa.containsMouse)
                anchors.right: parent.right
                anchors.rightMargin: Theme.gap(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.ctl(22); height: Theme.ctl(22); radius: 11
                role: rmMa.containsMouse ? "hover" : ""
                z: 2
                Icon { anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                       ink: rmMa.containsMouse ? "text" : "textFaint" }
                MouseArea {
                    id: rmMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (view.inLibrary) {
                            Library.removeTrackFromPlaylist(view.playlistId, row.model.vid)
                            view.dropTrack(row.model.vid)
                        } else {
                            view.hideTrack(row.model.vid)
                        }
                    }
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (m) => {
                    if (row.model.placeholder === true) return
                    const p = ma.mapToItem(null, m.x, m.y)
                    if (m.button === Qt.RightButton) {
                        if (view.trackMenu) view.trackMenu(view.rowTrack(row.model), p.x, p.y)
                    } else {
                        view.playAt(row.index)
                    }
                }
            }
        }
    }

    // ---------- grid ----------
    GridView {
        id: grid
        QQC.ScrollBar.vertical: MScrollBar {}
        // The header sits at negative content y (originY = -headerHeight), so the top
        // is originY, not 0. When originY moves, hold the top only if already at the top;
        // otherwise leave contentY alone. `atTop` derives from contentY because the wheel
        // sets it directly without starting a movement.
        property bool atTop: true
        onContentYChanged: atTop = contentY <= originY + 1
        function toTop() {
            if (!visible || moving || dragging) return
            if (atTop || contentY < originY) contentY = originY
        }
        onVisibleChanged: toTop()
        onOriginYChanged: toTop()
        onContentHeightChanged: toTop()
        anchors.top: header.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.bottom: parent.bottom
        anchors.bottomMargin: GridUi.padBottom
        anchors.horizontalCenter: parent.horizontalCenter
        readonly property int availW: parent.width - GridUi.padX - Theme.scrollGutter
        readonly property int gcols: GridUi.colsFor(availW, GridUi.growth)
        cellWidth: GridUi.cellWFor(availW, GridUi.growth)
        readonly property int slack: GridUi.slackOf(availW, gcols, cellWidth)
        // the whole box, not gcols * cellWidth: the slack is handed out per
        // column below, so an exact-fit width would only move the right edge
        width: availW + Theme.scrollGutter
        visible: view.layout === "grid"
        model: plModel
        clip: true
        reuseItems: true
        cacheBuffer: 400
        onAtYEndChanged: if (atYEnd && count > 0) view.loadMore()
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150 } }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 } }

        // scaled fixed-design text block — see HomeView's recGrid
        cellHeight: GridUi.cellHFor(cellWidth)

        delegate: Item {
            // A pooled delegate keeps what the remove transition left on it: that
            // transition fades opacity to 0, the item is pooled still at 0, and a
            // reused item is not an added one — so the add transition never runs
            // and the card comes back invisible, text and all.
            GridView.onReused: opacity = 1
            id: cell
            required property int index
            readonly property real slackX: GridUi.slackX(index % grid.gcols, grid.slack)
            required property var model
            width: grid.cellWidth
            height: grid.cellHeight

            MediaTile {
                selected: PlayerState.hasTrack && PlayerState.currentTrack.id === cell.model.vid
                anchors.fill: parent
                anchors.leftMargin: Theme.gap(4); anchors.rightMargin: Theme.gap(4)
                anchors.bottomMargin: Theme.gap(8)
                // The floor's leftover pixels, one per column in the gap (GridUi.slackX). A
                // Translate, not margins: margins relaid the tile every drag step (120 frames over
                // 33ms became 440); a transform only changes the node's matrix.
                transform: Translate { x: cell.slackX }
                title_: cell.model.title
                meta_: cell.model.channel
                art: cell.model.thumbnail || ""
                duration: cell.model.duration || 0
                loading: cell.model.placeholder === true
                tipTitle: true
                onClicked_: view.playAt(cell.index)
                onMenu: (sx, sy) => {
                    if (view.trackMenu) view.trackMenu(view.rowTrack(cell.model), sx, sy)
                }
            }
        }
    }

    // ONE handler, on the view rather than inside a list: a handler that
    // fills a column-width list only takes the wheel while the pointer is
    // over the rows, and the margin beside them is most of a wide window.
    WheelScroll { parent: view; target: view.layout === "grid" ? grid : list }

}
