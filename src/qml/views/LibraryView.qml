import QtQuick
import QtQuick.Controls as QQC
import ".."
import "../components"

// Library page: header (stats, Play All, sort bar),
// collapsible Playlists / Albums card sections, then all tracks in the shared
// list / grid / compact layouts. Rows filter live via Library.filter.
Item {
    id: view
    property var contextMenu: null
    property var trackMenu: null    // shared Main.openTrackMenu(t, sx, sy)
    property var prompt: null       // PromptDialog instance
    property string layout: "list"
    signal changeLayout(string mode)

    property bool playlistsCollapsed: Settings.uiGet("libPlaylistsCollapsed", false) === true
    property bool albumsCollapsed: Settings.uiGet("libAlbumsCollapsed", false) === true
    onPlaylistsCollapsedChanged: Settings.uiSet("libPlaylistsCollapsed", playlistsCollapsed)
    onAlbumsCollapsedChanged: Settings.uiSet("libAlbumsCollapsed", albumsCollapsed)
    // for the deleteTrack shortcut, which acts on the hovered row
    property string hoveredTrackId: ""
    signal openPlaylist(string playlistId, string title, var tracks)
    signal importFiles()

    // Right-click on empty space: the library's own menu. Beneath everything,
    // so a row, a card or a section header keeps its own.
    MouseArea {
        z: -1
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: (m) => {
            if (!view.contextMenu) return
            const all = Library.playAllTracks(false)
            const nd = all.filter((t) => !t.downloaded)
            const acts = [{ label: "Import Files…", act: () => view.importFiles() }]
            if (all.length) {
                acts.push({ label: "Play All", rule: true, act: () => Player.playQueue(all, 0) })
                acts.push({ label: "Shuffle All", act: () => Player.playQueue(Library.playAllTracks(true), 0) })
            }
            if (nd.length)
                acts.push({ label: "Download All (" + nd.length + ")", act: () => Library.downloadAll(nd.map((t) => t.id)) })
            acts.push({ label: "New Playlist…", rule: true, act: () =>
                view.prompt.promptDialog("New playlist name:", "", (n) => { if (n && n.trim()) Library.createPlaylist(n.trim()) }) })
            const p = mapToItem(null, m.x, m.y)
            view.contextMenu.open(p.x, p.y, acts)
        }
    }

    // addedAt is Date.now() from the sidecar: epoch milliseconds. Recent rows
    // read better relative and old ones read better absolute, which is the
    // split every file manager makes.
    function fmtAdded(ms) {
        if (!ms) return ""
        const d = new Date(ms)
        if (isNaN(d.getTime())) return ""
        const days = Math.floor((Date.now() - ms) / 86400000)
        if (days < 0) return ""
        if (days === 0) return "Today"
        if (days === 1) return "Yesterday"
        if (days < 7) return days + " days ago"
        if (d.getFullYear() === new Date().getFullYear())
            return d.toLocaleDateString(Qt.locale(), "d MMM")
        return d.toLocaleDateString(Qt.locale(), "MMM yyyy")
    }

    function fmtDur(s) {
        if (!s) return ""
        const m = Math.floor(s / 60)
        return m + ":" + (Math.floor(s % 60) < 10 ? "0" : "") + Math.floor(s % 60)
    }
    function rowTrack(m) {
        return { id: m.trackId, title: m.title, channel: m.channel,
                 duration: m.duration, thumbnail: m.thumbnail }
    }
    function shuffled(arr) {
        const a = arr.slice()
        for (let i = a.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1))
            const tmp = a[i]; a[i] = a[j]; a[j] = tmp
        }
        return a
    }
    function openRowMenu(m, sceneX, sceneY) {
        if (view.trackMenu) view.trackMenu(rowTrack(m), sceneX, sceneY)
    }
    function isActive(m) {
        return PlayerState.hasTrack && PlayerState.currentTrack.id === m.trackId
    }

    // ONE column math for the track grid AND the playlist/album cards —
    // fixed-width cards read smaller the moment the window grows the grid
    readonly property int gridAvailW: width - GridUi.padX - Theme.scrollGutter
    // ...but not one width: in list layout the playlist/album cards sit in the
    // list's centred column, so they size off it. Sized off the whole box they
    // wrapped early past ~1020px and shuffled on every resize step.
    readonly property int cardAvailW: layout === "grid" ? gridAvailW
                                                        : GridUi.listW(gridAvailW)
    readonly property int gridCols: GridUi.colsFor(cardAvailW, GridUi.growth)
    readonly property real gridCellW: GridUi.cellWFor(cardAvailW, GridUi.growth)

    function activeView() { return layout === "grid" ? grid : list }

    // contentY as it was when the section was clicked. By the time the view
    // reports originY changing, Qt has already clamped contentY into the new
    // bounds, and correcting from the clamped value lands short by however
    // much was clamped away (near the top of the header only).
    property real toggleCY: NaN
    function beginToggle() {
        const v = activeView()
        toggleCY = v ? v.contentY : NaN
    }

    // ---------- shared scrollable header ----------
    Component {
        id: libHeader
        Column {
            width: parent ? parent.width : view.width - 20
            spacing: Theme.gap(4)

            // the card sections; the heading is the page's own, above the scroller
            // collapsible card sections (playlists / albums)
            component SectionTitle: Item {
                property string label
                property bool collapsed: false
                property bool collapsible: true
                signal toggled()
                width: parent.width
                height: 26
                Row {
                    spacing: Theme.gap(6)
                    anchors.verticalCenter: parent.verticalCenter
                    InkText { text: parent.parent.label; ink: "textFaint"
                           font { pixelSize: Theme.fs(11); weight: Theme.weightBold
                                  family: Theme.fontFamily; letterSpacing: 0.5 } }
                    Icon { visible: parent.parent.collapsible
                           name: "chevron"; size: Theme.glyph(14); strokeWidth: 2.5
                           ink: "textFaint"
                           anchors.verticalCenter: parent.verticalCenter
                           rotation: parent.parent.collapsed ? 0 : 90
                           Behavior on rotation { NumberAnimation { duration: 120 } } }
                }
                MouseArea { anchors.fill: parent; enabled: parent.collapsible
                            onClicked: parent.toggled() }
            }
            component CardFlow: Flow {
                width: parent.width
                spacing: Theme.gap(8)
            }
            // the tile itself is MediaTile, shared with Home: undersized or
            // differently-drawn cards read as a different (wrong) kind of thing
            component Card: MediaTile {
                width: view.gridCellW - 8
            }

            SectionTitle {
                label: "PLAYLISTS"
                visible: Library.playlists.count > 0
                id: playlistsTitle
                collapsed: view.playlistsCollapsed
                onToggled: {
                    if (MELO_LIB_DEBUG) WindowCtl.logLine("[lib] --- toggle playlists -> " + !view.playlistsCollapsed + " cy=" + view.activeView().contentY.toFixed(1) + " ---")
                    view.beginToggle()
                    view.playlistsCollapsed = !view.playlistsCollapsed
                }
            }
            CardFlow {
                id: playlistsFlow
                visible: Library.playlists.count > 0 && !view.playlistsCollapsed
                Repeater {
                    model: Library.playlists
                    Card {
                        required property var model
                        title_: model.title
                        meta_: model.trackCount + " tracks"
                        art: model.thumbnail
                        onClicked_: view.openPlaylist(model.playlistId, model.title,
                                                      Library.playlistTracks(model.playlistId))
                        onMenu: (sx, sy) => {
                            if (!view.contextMenu) return
                            const pid = model.playlistId
                            const title = model.title
                            const pts = Library.playlistTracks(pid)
                            const nd = pts.filter((x) => !x.downloaded)
                            const acts = [
                                { label: "Play", act: () => { if (pts.length) Player.playQueue(pts, 0) } },
                                { label: "Play (Shuffled)", act: () => {
                                    const s = view.shuffled(pts)
                                    if (s.length) Player.playQueue(s, 0)
                                } },
                            ]
                            if (nd.length > 0)
                                acts.push({ label: "Download All (" + nd.length + ")",
                                            act: () => Library.downloadAll(nd.map((x) => x.id)) })
                            acts.push({ label: "Rename Playlist", act: () => {
                                view.prompt.promptDialog("New playlist name:", title, (n) => {
                                    if (n && n.trim() && n.trim() !== title)
                                        Library.renamePlaylist(pid, n.trim())
                                })
                            } })
                            acts.push({ label: "Delete Playlist Only",
                                        act: () => Library.removePlaylist(pid) })
                            view.contextMenu.open(sx, sy, acts)
                        }
                    }
                }
            }

            SectionTitle {
                label: "ALBUMS"
                visible: Library.albums.count > 0
                id: albumsTitle
                collapsed: view.albumsCollapsed
                onToggled: {
                    if (MELO_LIB_DEBUG) WindowCtl.logLine("[lib] --- toggle albums -> " + !view.albumsCollapsed + " cy=" + view.activeView().contentY.toFixed(1) + " ---")
                    view.beginToggle()
                    view.albumsCollapsed = !view.albumsCollapsed
                }
            }
            CardFlow {
                id: albumsFlow
                visible: Library.albums.count > 0 && !view.albumsCollapsed
                Repeater {
                    model: Library.albums
                    Card {
                        required property var model
                        title_: model.album
                        meta_: model.artist + " · " + model.trackCount + " tracks"
                        art: model.art
                        // an album opens like a playlist; Play is in the menu,
                        // as it is for playlists
                        onClicked_: view.openPlaylist("album:" + model.album, model.album,
                                                      Library.albumTracks(model.album))
                        onMenu: (sx, sy) => {
                            if (!view.contextMenu) return
                            const alb = model.album
                            const ts = Library.albumTracks(alb)
                            view.contextMenu.open(sx, sy, [
                                { label: "Play", act: () => { if (ts.length) Player.playQueue(ts, 0) } },
                                { label: "Play (Shuffled)", act: () => {
                                    const s = view.shuffled(ts)
                                    if (s.length) Player.playQueue(s, 0)
                                } },
                                { label: "Remove All Tracks from Library", act: () => {
                                    view.prompt.confirmDialog(
                                        "Remove all " + ts.length + " tracks in \"" + alb + "\" from library?",
                                        (ok) => {
                                            if (ok !== true) return
                                            const hasDl = ts.some((x) => x.downloaded)
                                            const doRemove = (del) =>
                                                ts.forEach((x) => Library.removeTrack(x.id, del === true))
                                            if (hasDl)
                                                view.prompt.confirmDialog("Also delete downloaded audio files?", doRemove)
                                            else
                                                doRemove(false)
                                        })
                                } },
                            ])
                        }
                    }
                }
            }

            SectionTitle {
                label: "TRACKS"
                collapsible: false
                visible: Library.playlists.count > 0 || Library.albums.count > 0
            }
        }
    }

    // ---------- tracks: list / compact ----------
    // The page's heading — the title row and the sort bar — sits above the
    // scroller like every other page's, measured from the page's own edge.
    Item {
        id: libHead
        objectName: "pageHeader"
        readonly property int availW: Math.max(0, parent.width - Theme.inset("pageHeader", "left")
                                                              - Theme.inset("pageHeader", "right"))
        readonly property int colW: view.layout === "grid" ? availW : GridUi.listW(availW)
        y: Theme.inset("pageHeader", "top")
        x: Theme.inset("pageHeader", "left") + Math.round((availW - colW) / 2)
        width: colW
        height: libHeadCol.height
        Column {
            id: libHeadCol
            width: parent.width
            spacing: Theme.gap(4)
            // title row: Library · n/m downloaded · Play All
            Item {
                width: parent.width
                height: 30
                Row {
                    spacing: Theme.gap(10)
                    anchors.verticalCenter: parent.verticalCenter
                    InkText { text: "Library"; ink: "text"
                           font { pixelSize: Theme.fs(16); weight: Theme.weightBold; family: Theme.fontFamily } }
                    InkText {
                        anchors.baseline: parent.children[0].baseline
                        text: Library.downloadedCount + "/" + Library.totalCount + " downloaded"
                        ink: "textFaint"
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                }
                PushButton {
                    id: playAllBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Library.totalCount > 0
                    pad: 20
                    label: "Play All"
                    onClicked: {
                        const p = playAllBtn.mapToItem(null, 0, playAllBtn.height)
                        view.contextMenu.open(p.x, p.y, [
                            { label: "In Order", act: () => Player.playQueue(Library.playAllTracks(false), 0) },
                            { label: "Shuffle", act: () => Player.playQueue(Library.playAllTracks(true), 0) },
                        ])
                    }
                }
            }

            // sort bar + layout toggle
            Item {
                width: parent.width
                height: 28
                SegmentTrack { strip: sortRow; style: Theme.chips }
                Row {
                    id: sortRow
                    spacing: Theme.chips === "segment" ? 0 : Theme.gap(2)
                    anchors.verticalCenter: parent.verticalCenter
                    component SortBtn: SelectTab {
                        property string key
                        property string name
                        active: Library.sortKey === key
                        hover: sbMa.containsMouse; pressed: sbMa.pressed
                        style: Theme.chips
                        label: name + (active ? (Library.sortAsc ? " ↑" : " ↓") : "")
                        fontSize: 11
                        width: implicitWidth; height: 22
                        MouseArea { id: sbMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        if (Library.sortKey === parent.key) Library.sortAsc = !Library.sortAsc
                                        else { Library.sortKey = parent.key; Library.sortAsc = parent.key === "title" || parent.key === "channel" }
                                    } }
                    }
                    SortBtn { key: "addedAt"; name: "Date" }
                    SortBtn { key: "title"; name: "Title" }
                    SortBtn { key: "channel"; name: "Artist" }
                    SortBtn { key: "duration"; name: "Duration" }
                }
                LayoutToggle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    layout: view.layout
                    onChanged_: (mode) => view.changeLayout(mode)
                }
            }
        }
    }

    ListView {
        id: list
        QQC.ScrollBar.vertical: MScrollBar {}
        // Not anchors.fill + margins: while the container is 0 tall at startup that
        // gives a negative height, and contentY stays parked negative for the session.
        // Held to a centred column (GridUi.listMaxW); the wheel works over the margins
        // because WheelScroll sits on the view.
        width: GridUi.listW(Math.max(0, parent.width - GridUi.padX))
        x: Math.round((parent.width - width) / 2)
        y: libHead.y + libHead.height + Theme.inset("pageHeader", "bottom")
        height: Math.max(0, parent.height - y - GridUi.padBottom)
        visible: view.layout !== "grid"
        model: Library.tracks
        clip: true
        spacing: Theme.gap(2)
        // The header sits at negative content y (originY = -headerHeight), so the top
        // is originY, not 0. The header is bottom-anchored and the first row stays at
        // content y 0, so header reflow moves the header's children; while the header is
        // in view contentY follows originY by the same delta to hold the screen still.
        // `atTop` derives from contentY because the wheel sets it directly without
        // starting a movement.
        property bool atTop: true
        property real lastOriginY: 0
        onContentYChanged: atTop = contentY <= originY + 1
        // ONLY here, and once per change: originY moving IS the header
        // resizing, and applying its delta from the other signals too shifted
        // the view by twice the amount.
        onOriginYChanged: {
            const d = originY - lastOriginY
            lastOriginY = originY
            if (!visible) return
            // A section toggle leaves its contentY behind and is applied regardless;
            // other origin moves (art landing mid-fling) wait, since writing contentY ends
            // the fling (GridUi.originHold).
            if (MELO_LIB_DEBUG)
                WindowCtl.logLine("[lib] originY " + (originY - d).toFixed(1) + " -> "
                    + originY.toFixed(1) + " (d=" + d.toFixed(1) + ")"
                    + " cy=" + contentY.toFixed(1) + " atTop=" + atTop
                    + " pays=" + (contentY < 0) + " moving=" + moving + " drag=" + dragging
                    + " ch=" + contentHeight.toFixed(1) + " h=" + height.toFixed(1))
            // the click's value when we have it, since Qt may already have
            // clamped contentY by now
            const toggling = !isNaN(view.toggleCY)
            const base = toggling ? view.toggleCY : contentY
            view.toggleCY = NaN
            const want = GridUi.originHold(!toggling && (moving || dragging), atTop, base, originY, d)
            if (!isNaN(want)) contentY = want
        }
        function holdView() {
            if (!visible || moving || dragging) return
            if (atTop || contentY < originY) contentY = originY
        }
        onVisibleChanged: holdView()
        onContentHeightChanged: holdView()


        headerPositioning: ListView.InlineHeader
        header: libHeader
        reuseItems: true
        cacheBuffer: 400

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
            width: Math.max(0, list.width - Theme.scrollGutter)
            height: Theme.sp(list.compact ? 26 : GridUi.rowH(width))
            radius: Theme.radiusMd
            role: view.isActive(model) ? "selected"
                 : ma.containsMouse ? "hover" : ""

            Row {
                anchors.fill: parent
                // The inset is the list row's padding; the compact row trims it,
                // never past the edge.
                anchors.topMargin: Theme.rowInset("top", list.compact ? 3 : 0)
                anchors.bottomMargin: Theme.rowInset("bottom", list.compact ? 3 : 0)
                anchors.leftMargin: Theme.inset("row", "left") + (list.compact ? 2 : 0)
                // a right-aligned value needs more air than a filled block
                anchors.rightMargin: Theme.rowInset("right", list.compact ? 8 : 0)
                spacing: list.compact ? 8 : 10

                Skeleton {
                    visible: !list.compact
                    width: GridUi.rowThumbW(parent.width)
                    height: Math.round(width * 9 / 16); radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    shimmer: false
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
                    // the right-hand group reserves its own width, tick
                    // included, so the duration is never clipped
                    width: Math.max(0, parent.width - GridUi.rowThumbW(parent.width)
                                       - parent.spacing - rowRight.width - 6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(2)
                    ScrollText { width: parent.width; text: row.model.title; ink: "text"
                                 hoverSource: ma
                                 font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily } }
                    ScrollText {
                        width: parent.width
                        // artist and album: the artist alone reads as an
                        // empty line at a wide column
                        text: (row.model.downloading ? "downloading… · " : "")
                              + row.model.channel
                              + (row.model.album ? " · " + row.model.album : "")
                        ink: row.model.downloading ? "highlight" : "textDim"
                        hoverSource: ma
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                }
                Row {   // added · downloaded · duration, as one group
                    id: rowRight
                    visible: !list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(10)
                    InkText {
                        anchors.verticalCenter: parent.verticalCenter
                        // only once the row is wide enough to have room for it
                        visible: row.width >= 760 && text.length > 0
                        text: view.fmtAdded(row.model.addedAt)
                        ink: "textSoft"
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.model.downloaded === true
                        width: visible ? 12 : 0
                        name: "check"; size: Theme.glyph(12)
                        ink: "textSoft"
                    }
                    InkText {
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        width: Math.max(Theme.sp(40), implicitWidth)
                        text: view.fmtDur(row.model.duration)
                        ink: "textSoft"
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                }

                // compact: title flexes, meta shrinks first (title >=80px)
                ScrollText {
                    id: cTitle
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth,
                           Math.max(80, parent.width - parent.spacing - cMeta.implicitWidth)))
                    text: row.model.title; ink: "text"
                    hoverSource: ma
                    font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily }
                }
                InkText {
                    id: cMeta
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - parent.spacing - cTitle.width)
                    text: row.model.channel
                          + (row.model.duration > 0 ? " · " + view.fmtDur(row.model.duration) : "")
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onContainsMouseChanged: {
                    if (containsMouse) view.hoveredTrackId = row.model.trackId
                    else if (view.hoveredTrackId === row.model.trackId) view.hoveredTrackId = ""
                }
                onClicked: (m) => {
                    const p = ma.mapToItem(null, m.x, m.y)
                    if (m.button === Qt.RightButton) view.openRowMenu(row.model, p.x, p.y)
                    else Player.playTrackData(view.rowTrack(row.model))
                }
            }
        }
    }

    // ---------- tracks: grid ----------
    GridView {
        id: grid

        QQC.ScrollBar.vertical: MScrollBar {}
        // same reason as the list above: never a negative height
        y: libHead.y + libHead.height + Theme.inset("pageHeader", "bottom")
        height: Math.max(0, parent.height - y - GridUi.padBottom)
        // LEFT-PINNED, not centred: the grid's total width moves in jumps of
        // `cols` px while resizing, and centring made the whole grid shimmy
        // ±cols/2 px on every step (the resize wobble). The remainder is
        // < cols px (≤ ~8px) of right-edge slack — invisible.
        x: GridUi.padLeft
        readonly property int cols: view.gridCols
        cellWidth: view.gridCellW
        readonly property int slack: GridUi.slackOf(view.gridAvailW, cols, cellWidth)
        // scaled fixed-design text block — see HomeView's recGrid
        cellHeight: GridUi.cellHFor(cellWidth)
        // full available width, not cols * cellWidth: the shared header takes
        // its width from this, and an exact-fit grid made the title row and
        // its buttons jump on every layout switch. The columns span it
        // exactly — the delegate hands the floor's leftover out per column.
        width: view.gridAvailW + Theme.scrollGutter
        visible: view.layout === "grid"
        model: Library.tracks
        clip: true
        reuseItems: true
        // 400, not 2000: a big buffer builds far-off delegates that each decode a
        // thumbnail, thrashing Qt's pixmap cache. Decode fell from 34% of cycles to 5%.
        cacheBuffer: 400
        // The header sits at negative content y (originY = -headerHeight), so the top
        // is originY, not 0. The header is bottom-anchored and the first row stays at
        // content y 0, so header reflow moves the header's children; while the header is
        // in view contentY follows originY by the same delta to hold the screen still.
        // `atTop` derives from contentY because the wheel sets it directly without
        // starting a movement.
        property bool atTop: true
        property real lastOriginY: 0
        onContentYChanged: atTop = contentY <= originY + 1
        // ONLY here, and once per change: originY moving IS the header
        // resizing, and applying its delta from the other signals too shifted
        // the view by twice the amount.
        onOriginYChanged: {
            const d = originY - lastOriginY
            lastOriginY = originY
            if (!visible) return
            // A section toggle leaves its contentY behind and is applied regardless;
            // other origin moves (art landing mid-fling) wait, since writing contentY ends
            // the fling (GridUi.originHold).
            if (MELO_LIB_DEBUG)
                WindowCtl.logLine("[lib] originY " + (originY - d).toFixed(1) + " -> "
                    + originY.toFixed(1) + " (d=" + d.toFixed(1) + ")"
                    + " cy=" + contentY.toFixed(1) + " atTop=" + atTop
                    + " pays=" + (contentY < 0) + " moving=" + moving + " drag=" + dragging
                    + " ch=" + contentHeight.toFixed(1) + " h=" + height.toFixed(1))
            // the click's value when we have it, since Qt may already have
            // clamped contentY by now
            const toggling = !isNaN(view.toggleCY)
            const base = toggling ? view.toggleCY : contentY
            view.toggleCY = NaN
            const want = GridUi.originHold(!toggling && (moving || dragging), atTop, base, originY, d)
            if (!isNaN(want)) contentY = want
        }
        function holdView() {
            if (!visible || moving || dragging) return
            if (atTop || contentY < originY) contentY = originY
        }
        onVisibleChanged: holdView()
        onContentHeightChanged: holdView()


        header: libHeader

        delegate: Item {
            // A pooled delegate keeps what the remove transition left on it: that
            // transition fades opacity to 0, the item is pooled still at 0, and a
            // reused item is not an added one — so the add transition never runs
            // and the card comes back invisible, text and all.
            GridView.onReused: opacity = 1
            id: cell
            required property int index
            required property var model
            readonly property real slackX: GridUi.slackX(index % grid.cols, grid.slack)
            width: grid.cellWidth
            height: grid.cellHeight

            MediaTile {
                selected: view.isActive(cell.model)
                id: gcell
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
                tipTitle: true
                onHoveredChanged: {
                    if (hovered) view.hoveredTrackId = cell.model.trackId
                    else if (view.hoveredTrackId === cell.model.trackId) view.hoveredTrackId = ""
                }
                onClicked_: Player.playTrackData(view.rowTrack(cell.model))
                onMenu: (sx, sy) => view.openRowMenu(cell.model, sx, sy)
            }
        }
    }

    // An empty library and an empty search are different pages: this counts
    // what the filter left, so a search matching nothing shows a message
    // rather than a blank page.
    InkText {
        anchors.centerIn: parent
        visible: Library.totalCount > 0
                 && Library.tracks.count === 0
                 && Library.playlists.count === 0
                 && Library.albums.count === 0
        text: "No results"
        ink: "textDim"
        font { pixelSize: Theme.fs(16); weight: Theme.weightMedium; family: Theme.fontFamily }
    }

    Column {
        anchors.centerIn: parent
        visible: Library.totalCount === 0
        spacing: Theme.gap(6)
        InkText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Library is empty"
            ink: "textDim"
            font { pixelSize: Theme.fs(16); weight: Theme.weightMedium; family: Theme.fontFamily }
        }
        InkText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "right-click a search result to add it"
            ink: "textFaint"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
        }
    }

    // ONE handler, on the view rather than inside a list: a handler that
    // fills a column-width list only takes the wheel while the pointer is
    // over the rows, and the margin beside them is most of a wide window.
    WheelScroll { parent: view; target: view.layout === "grid" ? grid : list }

}
