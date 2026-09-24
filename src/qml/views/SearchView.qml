import QtQuick
import QtQuick.Controls as QQC
import ".."
import "../components"
import "../components/skeletonmodel.js" as SkeletonModel

// Search results: list / grid / compact layouts with the
// LayoutToggle header bar. Model injected from Main.
Item {
    id: view
    property var model: null
    property var contextMenu: null
    property var trackMenu: null    // shared Main.openTrackMenu(t, sx, sy)
    property string layout: "list"
    property bool loadingMore: false
    property bool searching: false
    // merged-search source filter: [{id,name}] incl. {id:"youtube"}; the chip
    // row shows only when >1 source exists; filtering is client-side.
    property var sources: [{ id: "youtube", name: "YouTube" }]
    property string sourceFilter: "all"

    signal needMore()
    signal changeLayout(string mode)

    // placeholders needed to fill THIS view's viewport in the current layout
    // (shared math: grid counts always complete their rows)
    function placeholderCount() {
        return SkeletonModel.fillCount(layout, width, height, GridUi.growth)
    }

    // If a page of results doesn't overflow the viewport there's nothing to
    // scroll AND atYEnd never changes — keep fetching until it overflows.
    function maybeFillViewport() {
        if (view.searching || view.loadingMore) return
        const v = view.layout === "grid" ? grid : list
        if (v.count > 0 && v.contentHeight > 0 && v.contentHeight <= v.height)
            view.needMore()
    }
    onLoadingMoreChanged: if (!loadingMore) Qt.callLater(maybeFillViewport)

    signal openPlaylist(string playlistId, string title)

    function trackOf(m) {
        return { id: m.vid, title: m.title, channel: m.channel,
                 duration: m.duration, thumbnail: m.thumbnail,
                 source: m.src || "youtube",    // routes stream resolve by source
                 isPlaylist: m.isPlaylist === true }
    }
    function rowVisible(m) {
        return view.sourceFilter === "all" || (m.src || "youtube") === view.sourceFilter
    }
    function fmtDur(s) {
        if (!s) return ""
        const m = Math.floor(s / 60)
        return m + ":" + (Math.floor(s % 60) < 10 ? "0" : "") + Math.floor(s % 60)
    }
    function activate(t, mouseButton, sceneX, sceneY) {
        if (t.isPlaylist) {   // playlist result: open it (no track menu)
            if (mouseButton !== Qt.RightButton) view.openPlaylist(t.id, t.title)
            return
        }
        if (mouseButton === Qt.RightButton) {
            if (view.trackMenu) view.trackMenu(t, sceneX, sceneY)
        } else {
            Player.playTrackData(t)   // radio off, queue reset
        }
    }

    // --- layout bar ---
    Item {
        id: layoutBar
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
        height: 34
        // source filter chips (merged search) — only when >1 source
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.gap(4)
            visible: view.sources.length > 1
            Repeater {
                model: [{ id: "all", name: "All" }].concat(view.sources)
                Surface {
                    required property var modelData
                    width: chipText.implicitWidth + 16; height: 22
                    radius: Theme.pill(11)
                    role: view.sourceFilter === modelData.id ? "accent"
                         : Theme.faceOf("chip", chipMa.containsMouse)
                    InkText { id: chipText; anchors.centerIn: parent; text: modelData.name
                              ink: view.sourceFilter === modelData.id ? "textOnAccent" : "textDim"
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                    MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: view.sourceFilter = modelData.id }
                }
            }
        }
        LayoutToggle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            layout: view.layout
            onChanged_: (mode) => view.changeLayout(mode)
        }
    }

    // --- list / compact ---
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
        anchors.top: layoutBar.bottom
        anchors.topMargin: Theme.inset("pageHeader", "bottom")
        anchors.bottom: parent.bottom
        anchors.bottomMargin: GridUi.padBottom
        // held to a column and centred; the view carries the wheel handler
        width: GridUi.listW(Math.max(0, parent.width - GridUi.padX))
        x: Math.round((parent.width - width) / 2)
        visible: view.layout !== "grid"
        model: view.model
        clip: true
        spacing: Theme.gap(2)
        onAtYEndChanged: if (atYEnd && count > 0 && !view.searching) view.needMore()
        onCountChanged: Qt.callLater(view.maybeFillViewport)
        onHeightChanged: { toTop(); Qt.callLater(view.maybeFillViewport) }
        reuseItems: true
        cacheBuffer: 400
        // model corrections must animate, not pop: excess placeholders fade
        // out, appended pages fade in, shifted rows slide
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
            readonly property bool shown: view.rowVisible(model)   // source filter
            width: Math.max(0, list.width - Theme.scrollGutter)
            height: shown ? Theme.sp(list.compact ? 26 : GridUi.rowH(width)) : 0
            visible: shown
            radius: Theme.radiusMd
            role: ma.containsMouse ? "hover" : ""

            // list: thumb + two-line info + duration; compact: single line
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

                // list layout: stacked title / channel (placeholder rows morph)
                Column {
                    visible: !list.compact
                    width: Math.max(0, parent.width - GridUi.rowThumbW(parent.width)
                                 - 10 - srchDur.width - 10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(2)
                    SkeletonText { width: parent.width; text: row.model.title; ink: "text"
                                   hoverSource: ma
                                   loading: row.model.placeholder === true
                                   placeholderWidth: Theme.sp(180 + ((row.index * 53) % 260)); barHeight: 13
                                   font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily } }
                    SkeletonText { width: parent.width
                                   // views and age come down with every result
                                   text: row.model.channel
                                         + (row.model.views ? " · " + row.model.views : "")
                                         + (row.model.age ? " · " + row.model.age : "")
                                   ink: "textDim"
                                   hoverSource: ma
                                   loading: row.model.placeholder === true
                                   placeholderWidth: Theme.sp(160 + ((row.index * 29) % 60)); barHeight: 11
                                   font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                }
                Column {
                    id: srchDur
                    visible: !list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    SkeletonValue {   // duration / count: morphs, never marquees
                        anchors.right: parent.right
                        width: Math.max(Theme.sp(44), textW)
                        alignRight: true
                        text: row.model.placeholder === true ? ""
                              : (row.model.isPlaylist ? row.model.videoCount + " videos"
                                                      : view.fmtDur(row.model.duration))
                        loading: row.model.placeholder === true
                        placeholderWidth: 30; barHeight: 11
                        color: Theme.textSoft
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                    // source badge for non-YouTube (plugin) results
                    InkText {
                        anchors.right: parent.right
                        visible: (row.model.src || "youtube") !== "youtube"
                        text: row.model.src || ""
                        ink: "highlight"
                        font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                    }
                }

                // compact: title flexes into whatever the meta doesn't need;
                // when tight the META shrinks first, title keeps >=80px
                SkeletonText {
                    id: cTitle
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth,
                           Math.max(80, parent.width - parent.spacing - cMeta.implicitWidth)))
                    text: row.model.title; ink: "text"
                    hoverSource: ma
                    loading: row.model.placeholder === true
                    // container width is invisible and already final when the
                    // morph measures (one tick after the flip) — safe to morph,
                    // same as HomeView's hcTitle and PlaylistView's pcTitle
                    placeholderWidth: Theme.sp(170 + ((row.index * 37) % 200)); barHeight: 13
                    font { pixelSize: Theme.fs(13); weight: Theme.weightMedium; family: Theme.fontFamily }
                }
                SkeletonText {
                    id: cMeta
                    // inline bar pair with the title, as HomeView and
                    // PlaylistView do. Both bars must morph: with morph off on
                    // the title its element width snaps while the meta's x
                    // follows it, which reads as the compact list jumping.
                    visible: list.compact
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - parent.spacing - cTitle.width)
                    text: row.model.isPlaylist
                          ? row.model.channel + " · Playlist"
                          : row.model.channel
                            + (row.model.duration > 0 ? " · " + view.fmtDur(row.model.duration) : "")
                    ink: "textDim"
                    hoverSource: ma
                    loading: row.model.placeholder === true
                    // varied: a constant width resolves every row in lockstep
                    placeholderWidth: Theme.sp(70 + ((row.index * 29) % 60)); barHeight: 11
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
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
                    view.activate(view.trackOf(row.model), m.button, p.x, p.y)
                }
            }
        }
    }

    // --- grid (cells at least 160px wide, 16:9 thumbs) ---
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
        anchors.top: layoutBar.bottom
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
        model: view.model
        clip: true
        onAtYEndChanged: if (atYEnd && count > 0 && !view.searching) view.needMore()
        onCountChanged: Qt.callLater(view.maybeFillViewport)
        onHeightChanged: { toTop(); Qt.callLater(view.maybeFillViewport) }
        reuseItems: true
        cacheBuffer: 400
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
            // source filter — GridView cells are fixed-size, so a filtered
            // cell blanks in place (leaves a gap) rather than collapsing
            readonly property bool shown: view.rowVisible(model)
            width: grid.cellWidth
            height: grid.cellHeight
            visible: shown

            MediaTile {
                selected: !cell.model.isPlaylist && PlayerState.hasTrack && PlayerState.currentTrack.id === cell.model.vid
                anchors.fill: parent
                anchors.leftMargin: Theme.gap(4); anchors.rightMargin: Theme.gap(4)
                anchors.bottomMargin: Theme.gap(8)
                // The floor's leftover pixels, one per column in the gap (GridUi.slackX). A
                // Translate, not margins: margins relaid the tile every drag step (120 frames over
                // 33ms became 440); a transform only changes the node's matrix.
                transform: Translate { x: cell.slackX }
                title_: cell.model.title
                // a playlist has no runtime to badge, so its count stays in
                // the meta line where the duration would be
                meta_: cell.model.isPlaylist
                       ? cell.model.channel + " · Playlist · " + cell.model.videoCount + " videos"
                       : cell.model.channel
                art: cell.model.thumbnail || ""
                duration: cell.model.isPlaylist ? 0 : (cell.model.duration || 0)
                loading: cell.model.placeholder === true
                tipTitle: true
                // activate() takes the button, so both routes go through it
                onClicked_: (sx, sy) => view.activate(view.trackOf(cell.model), Qt.LeftButton, sx, sy)
                onMenu: (sx, sy) => view.activate(view.trackOf(cell.model), Qt.RightButton, sx, sy)
            }
        }
    }

    InkText {
        anchors.centerIn: parent
        visible: !view.searching && (view.layout === "grid" ? grid.count : list.count) === 0
        text: "no results"
        ink: "textFaint"
        font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
    }

    // ONE handler, on the view rather than inside a list: a handler that
    // fills a column-width list only takes the wheel while the pointer is
    // over the rows, and the margin beside them is most of a wide window.
    WheelScroll { parent: view; target: view.layout === "grid" ? grid : list }

}
