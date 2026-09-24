import QtQuick
import QtQuick.Controls as QQC
import ".."

// Right-side queue panel:
// page tabs, edge-to-edge 48px rows (64x36 thumbs), right-aligned header
// with icon buttons, AUTOPLAY/SUGGESTIONS section labels when no queue,
// removal via the right-click menu or the row's hover close button.
Rectangle {
    id: panel
    width: 320
    color: "transparent"   // the ground is the Surface below

    // A row sits closer in than the header does (6 against the header's 12)
    // because its thumbnail carries an edge of its own. It keeps that half
    // step as the inset moves.
    readonly property real rowLeft: Math.max(0, Theme.inset("panel", "left") - Theme.gap(6))

    // The panel's ground as a role, so a theme can blend or adapt it like any
    // other surface rather than only colour it.
    Surface { anchors.fill: parent; z: -1; role: "panel" }
    clip: true
    // mini popup: a separate rounded card (all four corners) floating above
    // the bar with a gap — reads as its own element, not fused to the bar
    topLeftRadius: fullWidth ? Theme.windowRadius : 0
    topRightRadius: fullWidth ? Theme.windowRadius : 0
    bottomLeftRadius: fullWidth ? Theme.windowRadius : 0
    bottomRightRadius: fullWidth ? Theme.windowRadius : 0
    // the appearance window-border outline, on the mini popup card
    border.color: (fullWidth && Theme.windowBorder) ? Theme.windowBorderColor : "transparent"
    border.width: (fullWidth && Theme.windowBorder) ? Theme.windowBorderWidth : 0

    property var contextMenu: null   // ContextMenu instance from Main
    property bool fullWidth: false   // mini queue popup: spans the bar, no side border

    // the mini popup has no app tab bar, so now playing lives here for it;
    // in full mode it is a main view instead
    property bool miniHost: false
    // A stored panelMode of 2 names a Now playing tab this panel no longer
    // has; map it to Suggestions.
    Component.onCompleted: if (PlayerState.panelMode === 2) PlayerState.panelMode = 0
    readonly property bool hasQueue: Queue.count > 1
    readonly property bool queueMode: hasQueue && PlayerState.panelMode === 1

    function fmtDur(s) {
        if (!s) return ""
        const m = Math.floor(s / 60)
        return m + ":" + (Math.floor(s % 60) < 10 ? "0" : "") + Math.floor(s % 60)
    }

    // full-window mode: left divider from the view it overlays. In the mini
    // popup (fullWidth) the rounded card shape defines the top edge — no line
    // (a straight line clipped by the rounded corners read as broken).
    Surface { visible: !panel.fullWidth; anchors.left: parent.left
              width: 1; height: parent.height; role: "border"; z: 5 }

    Column {
        anchors.fill: parent

        // tabs: in the style the theme gives page tabs
        Item {
            width: parent.width
            // at least the tabs and a segment track's pad around them
            readonly property real trackPad: Theme.pageTabs === "segment" ? Theme.tabTrackPad : 0
            height: Math.max(Theme.sp(32), Theme.tabHeight + 2 * trackPad)
            visible: panel.hasQueue || (panel.miniHost && PlayerState.hasTrack)
            Surface { anchors.fill: parent; z: -1; role: "panelHeader" }

            component QTab: SelectTab {
                property int mode: 0
                active: PlayerState.panelMode === mode
                hover: qtMa.containsMouse; pressed: qtMa.pressed
                style: Theme.pageTabs
                fontSize: 12
                height: line ? parent.height : Theme.tabHeight
                anchors.verticalCenter: parent.verticalCenter
                MouseArea { id: qtMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: PlayerState.panelMode = parent.mode }
            }
            SegmentTrack { strip: qtabs; style: Theme.pageTabs }
            Row {
                id: qtabs
                anchors.fill: parent
                // underlined tabs share the strip; filled ones and pills sit
                // at their own width from the left, segments on their track
                readonly property bool full: Theme.pageTabs === "underline"
                readonly property int tabs: panel.hasQueue ? 2 : 1
                anchors.leftMargin: full ? 0 : Theme.gap(8) + parent.trackPad
                spacing: (full || Theme.pageTabs === "segment") ? 0 : Theme.gap(2)
                QTab { label: "Suggestions"; mode: 0; width: parent.full ? parent.width / parent.tabs : implicitWidth }
                QTab { label: "Queue (" + Queue.count + ")"; mode: 1
                       visible: panel.hasQueue
                       width: !panel.hasQueue ? 0 : parent.full ? parent.width / parent.tabs : implicitWidth }
            }
        }

        // queue header: count + icon buttons, right-aligned
        Item {
            width: parent.width
            height: 44
            visible: panel.queueMode
            Surface { anchors.fill: parent; z: -1; role: "panelHeader" }

            // the panel's own tools: framed icon buttons, the square the theme gives them
            component QBtn: Item {
                id: qb
                property string glyph
                signal clicked()
                width: Theme.iconBtn; height: Theme.iconBtn
                IconButton {
                    anchors.centerIn: parent
                    framed: true
                    name: qb.glyph; size: Theme.glyph(14)
                    ink: qbMa.containsMouse ? "text" : "textSoft"
                    hovered: qbMa.containsMouse; pressed: qbMa.pressed
                }
                MouseArea { id: qbMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: qb.clicked() }
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.inset("panel", "right")
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap(8)
                InkText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (Queue.currentIndex + 1) + " / " + Queue.count
                    ink: "textDim"
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                }
                QBtn { glyph: "shuffle"; visible: Queue.count - Queue.currentIndex > 2
                       onClicked: Player.shuffleQueue() }
                QBtn { glyph: "close"; onClicked: Player.clearQueue() }
            }
            Surface { anchors.bottom: parent.bottom; width: parent.width
                      height: 1; role: "button" }
        }

        ListView {
            id: list
            QQC.ScrollBar.vertical: MScrollBar {}
            width: parent.width
            height: parent.height - y
            clip: true
            model: panel.queueMode ? Queue : Suggestions
            // the rows a drag passes slide out of its way; the dragged row
            // itself takes its new slot instantly (no `move` transition) —
            // the handler's offset already carries it across the swap
            displaced: Transition {
                NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutCubic }
            }

            // Reaching the end of the QUEUE should extend the mix, same as the
            // playlist view. atYEnd only fires on a change, so short content or
            // sitting at the bottom also has to be handled explicitly.
            function maybeLoadMore() {
                if (count === 0) return
                const more = panel.queueMode ? Player.queueHasMore()
                                             : Player.suggestionsHaveMore()
                if (!more) return
                if (!((contentHeight > 0 && contentHeight <= height) || atYEnd)) return
                if (panel.queueMode) Player.loadMoreQueue()
                else Player.loadMoreSuggestions()
            }
            onAtYEndChanged: if (atYEnd) maybeLoadMore()
            onCountChanged: Qt.callLater(maybeLoadMore)
            WheelScroll { target: list }

            // the next page is coming: say so under the last row
            footer: Item {
                readonly property bool busy: panel.queueMode ? Player.queueLoading
                                                             : (Player.suggestionsLoading && list.count > 0)
                width: list.width - Theme.scrollGutter
                height: busy ? 44 : 0
                Spinner { anchors.centerIn: parent; running: parent.busy; implicitWidth: 18 }
            }

            // AUTOPLAY / SUGGESTIONS section labels — only when no queue
            section.property: (!panel.queueMode && !panel.hasQueue) ? "isAutoplay" : ""
            section.criteria: ViewSection.FullString
            section.delegate: Item {
                width: list.width - Theme.scrollGutter
                height: Theme.sp(26)
                // the header rows of a panel with no queue: what the tab strip
                // is once there is one
                Surface { anchors.fill: parent; z: -1; role: "panelHeader" }
                InkText {
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.inset("panel", "left"); anchors.bottomMargin: Theme.gap(4)
                    text: section === "true" ? "AUTOPLAY" : "SUGGESTIONS"
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(11); weight: Theme.weightBold
                           family: Theme.fontFamily; letterSpacing: 0.5 }
                }
            }

            delegate: Surface {
                id: row
                required property int index
                required property var model
                readonly property bool autoplayItem: !panel.queueMode && !panel.hasQueue
                                                     && (model.isAutoplay === true)
                width: list.width - Theme.scrollGutter
                height: 48
                // a dragged row rides above its neighbours and follows the
                // cursor; the rows it passes settle into place behind it
                property bool dragging: false
                property real dragOffset: 0
                z: dragging ? 2 : 0
                transform: Translate { y: row.dragOffset }
                role: dragging ? "selected"
                     : (panel.queueMode && model.active) ? "selected"
                     : (autoplayItem || rowMa.containsMouse) ? "hover"
                     : ""
                opacity: (panel.queueMode && model.played && !dragging) ? 0.5 : 1

                Surface {   // autoplay accent edge
                    visible: row.autoplayItem
                    anchors.left: parent.left
                    width: 2; height: parent.height
                    role: "accent"
                }

                // The row's content builds off the frame: the suggestions land
                // as one list, and twenty rows built in the frame they land in
                // take 80–200 ms of it. Until it is ready the row wears the
                // skeleton the loading rows wear.
                Row {
                    visible: content.status !== Loader.Ready
                    anchors.fill: parent
                    anchors.leftMargin: panel.rowLeft + (panel.queueMode ? 24 + Theme.gap(10) : 0)
                    anchors.rightMargin: Theme.inset("panel", "right")
                    anchors.topMargin: Theme.inset("panel", "top"); anchors.bottomMargin: Theme.inset("panel", "bottom")
                    spacing: Theme.gap(10)
                    Skeleton { width: 64; height: 36; radius: Theme.radiusSm; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        Skeleton { width: 150; height: 10; radius: 3 }
                        Skeleton { width: 90; height: 8; radius: 3 }
                    }
                }
                Loader {
                    id: content
                    anchors.fill: parent
                    asynchronous: true
                    sourceComponent: rowContent
                }
                Component {
                    id: rowContent
                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: panel.rowLeft; anchors.rightMargin: Theme.inset("panel", "right")
                        anchors.topMargin: Theme.inset("panel", "top"); anchors.bottomMargin: Theme.inset("panel", "bottom")
                        spacing: Theme.gap(10)

                        Item {   // queue position, and the reorder grip on hover
                            visible: panel.queueMode
                            width: 24
                            height: parent.height
                            anchors.verticalCenter: parent.verticalCenter
                            InkText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !rowMa.containsMouse
                                text: row.index + 1
                                ink: model.active ? "highlight" : "textFaint"
                                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            }
                            // the reorder grip, so the drag zone is visible
                            Grid {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowMa.containsMouse
                                columns: 2; rowSpacing: 3; columnSpacing: 3
                                Repeater {
                                    model: 6
                                    Rectangle { width: Theme.ctl(2); height: Theme.ctl(2); radius: 1
                                                color: Theme.textFaint }
                                }
                            }
                        }
                        Skeleton {   // thumb 64x36
                            width: 64; height: 36; radius: Theme.radiusSm
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
                            width: Math.max(0, parent.width - (panel.queueMode ? 24 + 10 : 0) - 64 - 10)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(2)
                            ScrollText {
                                width: parent.width
                                text: row.model.title || "Loading..."
                                ink: "text"
                                hoverSource: rowMa
                                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            }
                            ScrollText {
                                width: parent.width
                                text: row.model.channel
                                      + (row.model.duration > 0 ? " · " + panel.fmtDur(row.model.duration) : "")
                                ink: "textDim"
                                hoverSource: rowMa
                                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                            }
                        }
                    }
                }

                // take this row out of the queue. Above rowMa so the click
                // does not fall through and jump playback to it; its own hover
                // is part of the visible test, or it would vanish when aimed at
                Surface {
                    id: rmBtn
                    visible: panel.queueMode && (rowMa.containsMouse || rmMa.containsMouse)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.gap(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.ctl(22); height: Theme.ctl(22); radius: 11
                    role: rmMa.containsMouse ? "hover" : ""
                    z: 3
                    Icon { anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                           ink: rmMa.containsMouse ? "text" : "textFaint" }
                    MouseArea {
                        id: rmMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: Player.removeFromQueue(row.index)
                    }
                }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (m) => {
                        if (m.button === Qt.RightButton) {
                            if (!panel.contextMenu) return
                            const p = rowMa.mapToItem(null, m.x, m.y)
                            const i = row.index
                            const t = { id: row.model.trackId, title: row.model.title,
                                        channel: row.model.channel, duration: row.model.duration,
                                        thumbnail: row.model.thumbnail }
                            const acts = panel.queueMode
                                ? [ { label: "Play", act: () => Player.jumpQueue(i) },
                                    { label: "Remove from queue", act: () => Player.removeFromQueue(i) } ]
                                : [ { label: "Play", act: () => Player.playSuggestion(i) },
                                    { label: "Add to next up", act: () => Player.playNext([t]) },
                                    { label: "Add to Queue", act: () => Player.addToQueue([t]) } ]
                            if (t.id && !String(t.id).startsWith("local-"))
                                acts.push({ label: "Copy link",
                                            act: () => WindowCtl.copyToClipboard(
                                                "https://www.youtube.com/watch?v=" + t.id) })
                            panel.contextMenu.open(p.x, p.y, acts)
                            return
                        }
                        if (panel.queueMode) Player.jumpQueue(row.index)
                        else Player.playSuggestion(row.index)
                    }
                }

                // drag reorder (queue mode): vertical drag on the index column
                MouseArea {
                    id: dragArea
                    visible: panel.queueMode
                    width: 34; height: parent.height
                    cursorShape: Qt.SizeVerCursor
                    // the list is a Flickable and a reorder drag is vertical:
                    // without this it hands the grab to the scroll every time
                    preventStealing: true
                    property int startIdx: -1
                    // the press point lives in the LIST's coordinates: this
                    // MouseArea travels with the row, so measuring inside it
                    // moves the origin on every reorder and the drag jumps
                    property real pressY: 0
                    // cursor height within the viewport, kept so the drag can
                    // be re-evaluated while the content scrolls under a still
                    // cursor
                    property real viewY: 0

                    // reaching a slot off-screen should not mean letting go:
                    // near either edge the list scrolls, faster the closer the
                    // cursor is to it
                    readonly property real band: 56
                    readonly property real edgeSpeed: {
                        if (startIdx < 0) return 0
                        if (viewY < band) return -Math.min(14, (band - viewY) / 4)
                        if (viewY > list.height - band)
                            return Math.min(14, (viewY - (list.height - band)) / 4)
                        return 0
                    }
                    Timer {
                        interval: 16; repeat: true
                        running: dragArea.edgeSpeed !== 0
                        onTriggered: {
                            const maxY = Math.max(0, list.contentHeight - list.height)
                            list.contentY = Math.max(0, Math.min(maxY,
                                                     list.contentY + dragArea.edgeSpeed))
                            dragArea.evaluate()
                        }
                    }

                    // swap once the row is more than half over its neighbour,
                    // carrying the origin with it so the row keeps tracking
                    // the cursor across the swap
                    function evaluate() {
                        if (startIdx < 0) return
                        let off = list.contentItem.mapFromItem(list, 0, viewY).y - pressY
                        // Swap no further than the viewport's edge: a cursor far above the list
                        // would swap the row off screen, where ListView destroys the delegate and
                        // the drag's grab with it. The edge scroll reveals the next row for the
                        // next tick.
                        const top = list.indexAt(4, list.contentY + 1)
                        const bot = list.indexAt(4, list.contentY + list.height - 1)
                        const lo = top < 0 ? 0 : top
                        const hi = bot < 0 ? Queue.count - 1 : bot
                        while (off > row.height / 2 && startIdx < Math.min(Queue.count - 1, hi)) {
                            Player.reorderQueue(startIdx, startIdx + 1)
                            startIdx++; pressY += row.height; off -= row.height
                        }
                        while (off < -row.height / 2 && startIdx > lo) {
                            Player.reorderQueue(startIdx, startIdx - 1)
                            startIdx--; pressY -= row.height; off += row.height
                        }
                        // once the row is at an end, extra cursor travel must
                        // not carry it out of the list and under the clip —
                        // it read as the drag dropping
                        const minOff = -row.y
                        const maxOff = Math.max(minOff,
                                                list.contentHeight - row.height - row.y)
                        row.dragOffset = Math.max(minOff, Math.min(maxOff, off))
                    }

                    onPressed: (m) => {
                        startIdx = row.index
                        viewY = mapToItem(list, m.x, m.y).y
                        pressY = list.contentItem.mapFromItem(list, 0, viewY).y
                        row.dragOffset = 0
                        row.dragging = true
                    }
                    onPositionChanged: (m) => {
                        if (startIdx < 0) return
                        viewY = mapToItem(list, m.x, m.y).y
                        evaluate()
                    }
                    function endDrag() {
                        startIdx = -1
                        row.dragging = false
                        row.dragOffset = 0
                    }
                    onReleased: endDrag()
                    onCanceled: endDrag()
                }
            }
        }

    }

    // While suggestions load, rows of skeleton in the rows' own shape (the
    // thumb, a title bar, a meta bar), as every other list shows; the empty
    // message is only for a fetch that finished with nothing.
    readonly property real emptyTop: Theme.gap(24) + ((panel.hasQueue || (panel.miniHost && PlayerState.hasTrack)) ? 32 : 0)
    Column {
        anchors.top: parent.top
        anchors.topMargin: panel.emptyTop - Theme.gap(12)
        width: parent.width
        visible: !panel.queueMode && list.count === 0 && Player.suggestionsLoading
        Repeater {
            model: 4
            Item {
                width: parent.width; height: 52
                Row {
                    anchors.fill: parent; anchors.margins: Theme.gap(10)
                    spacing: Theme.gap(10)
                    Skeleton { width: 64; height: 36; radius: Theme.radiusSm; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        Skeleton { width: 150; height: 10; radius: 3 }
                        Skeleton { width: 90; height: 8; radius: 3 }
                    }
                }
            }
        }
    }
    InkText {
        anchors.top: parent.top
        anchors.topMargin: panel.emptyTop
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !panel.queueMode && list.count === 0 && !Player.suggestionsLoading
        text: "No suggestions available"
        ink: "textFaint"
        font { pixelSize: Theme.fs(13); family: Theme.fontFamily }
    }
}
