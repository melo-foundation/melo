import QtQuick

// Cards laid out as a Flow of equal cards would lay them, inside an outer
// scroller. The inner view is one viewport tall and slides down the section
// with the scroller, so only the rows near the viewport are built: 2,000 albums
// are ~40 live cards.
Item {
    id: sec
    property alias model: cv.model
    property alias delegate: cv.delegate
    property real cardWidth: 160
    property real cardHeight: 160
    property real spacing: 0
    // the scroller's viewport, in this item's coordinates
    property real viewTop: 0
    property real viewHeight: 0

    // a Flow wraps a card when x + width > the row's width
    readonly property int cols: Math.max(1, Math.floor((width + spacing + 0.001) / (cardWidth + spacing)))
    readonly property int rows: Math.ceil(cv.count / cols)
    // a page not shown yet has no viewport: build no rows for it
    readonly property bool shown: viewHeight > 0 && width > 0
    height: rows > 0 ? rows * cardHeight + (rows - 1) * spacing : 0

    GridView {
        id: cv
        interactive: false
        // half a pixel over so floor(width / cellWidth) cannot land one short;
        // one column until shown
        width: (sec.shown ? sec.cols : 1) * cellWidth + 0.5
        cellWidth: sec.cardWidth + sec.spacing
        cellHeight: sec.cardHeight + sec.spacing
        height: sec.shown ? Math.min(sec.height, sec.viewHeight) : 0
        y: Math.max(0, Math.min(sec.height - height, sec.viewTop))
        // held to y, the rows under the viewport: a model reset moves
        // contentY back to the top without touching y
        onYChanged: contentY = y
        onContentYChanged: if (contentY !== y) contentY = y
        Component.onCompleted: contentY = y
        reuseItems: true
        cacheBuffer: sec.shown ? 400 : 0
    }
}
