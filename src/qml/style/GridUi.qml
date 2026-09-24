pragma Singleton
import QtQuick

// Shared tile-grid column math. Minimum tile size grows with available width
// (168 + availW*growth%), so bigger windows get bigger tiles. `growth` is
// ui.tileGrowth; grids pass it in so the setting applies live.
Item {
    visible: false
    property real growth: 4

    // The margin every view leaves (theme `insets.page`), so a grid and a list of
    // the same content get the same rect and tile size. Bindings re-evaluate when the
    // theme changes.
    readonly property int padLeft: Theme.inset("page", "left")
    readonly property int padTop: Theme.inset("page", "top")
    readonly property int padRight: Theme.inset("page", "right")
    readonly property int padBottom: Theme.inset("page", "bottom")
    // the pair a full-width box loses, which is how every view asks for it
    readonly property int padX: padLeft + padRight
    readonly property int padY: padTop + padBottom

    // Where a window stops being wide enough to put two things side by side.
    // The now-playing page and the player bar rearrange on the SAME number, so
    // they change together instead of one at a time.
    readonly property int narrowW: 820

    // Lists hold to a readable column (as Spotify and SoundCloud do); full-width
    // rows lose the eye between title and artist. Grids use the width for more tiles.
    readonly property int listMaxW: 1000
    function listW(availW) { return Math.min(availW, listMaxW) }

    // A thumbnail-list row grows with its column instead of staying at the
    // size a narrow window needs. 52px of row and a 64px thumb read fine at
    // 400px wide and look lost at 1000: the references use a noticeably
    // larger tile once there is room for one.
    function rowH(w) { return w >= 760 ? 64 : 52 }
    function rowThumbW(w) { return Theme.art(w >= 760 ? 96 : 64) }

    // `g` is passed rather than read from the singleton on purpose: a binding
    // that calls a function does not depend on what the function happens to
    // read, so tile growth would stop applying live the moment the formula
    // moved in here. Callers pass GridUi.growth and stay bound to it.
    function colsFor(availW, g) {
        return Math.max(1, Math.floor(availW / (Theme.art(168) + availW * g / 100)))
    }
    // Tile math floors to device pixels, not logical ones: at 200% a logical floor
    // jumps two device px per tile every few drag steps. `dev` equals floor at 100%.
    // Main.qml pushes the window's ratio; 1 until then.
    property real dpr: 1
    function dev(v) { return Math.floor(v * dpr) / dpr }
    // A knob centred on a track must differ from it by an even number of device
    // pixels, or it sits half a pixel off (at 1.9, a 16px knob over a 6px track).
    // Sizes snap to device pixels; the knob gives or takes one to match.
    function snap(v) { return Math.max(1, Math.round(v * dpr)) / dpr }
    function knobOn(knob, track) {
        const k = Math.max(1, Math.round(knob * dpr)), t = Math.max(1, Math.round(track * dpr))
        return ((k - t) % 2 === 0 ? k : k + 1) / dpr
    }
    // where a centred child of height h starts inside a parent of height H,
    // on a whole device pixel
    function centreIn(H, h) { return Math.round((H - h) * dpr / 2) / dpr }

    function cellWFor(availW, g) {
        return Math.max(1, dev(availW / colsFor(availW, g)))
    }
    // Spreads the floor's leftover (availW % cols) a pixel per column instead of at
    // the right edge, where it breathes during a left-edge drag and shifts the last
    // column and scrollbar. The pixel goes in the gap: a wider card is taller (16:9
    // art) and captions go ragged. `slack` is in device pixels; the views compute it.
    function slackX(col, slack) { return Math.min(col, slack) / dpr }
    function slackOf(availW, cols, cellW) { return Math.round((availW - cols * cellW) * dpr) }
    // 53 is the caption band in 160px design units (MediaTile's 45px text block
    // plus padding, two title lines and one meta line), scaled with type or the third
    // line falls off the card. Read once per theme, not per tile inside cellHFor.
    readonly property int captionBand: Theme.sp(53)
    function cellHFor(cellW) {
        return dev((cellW - 8) * 9 / 16)
             + Math.round(captionBand * (cellW - 8) / 160 * dpr) / dpr
    }
    // Thumbnail decode size. Qt decodes at file size unless told: a 720x404 cover
    // is 1.16MB for a 274px card, and the pixmap cache held about one, so scrolling
    // back re-decoded (568ms vs 38ms once they fit). libjpeg scales during decode.
    // Must be a constant: bound to a live width it re-decodes and blanks on drag.
    property string thumbQuality: "medium"
    readonly property int cardPx: thumbQuality === "low" ? 180
                                : thumbQuality === "high" ? 720 : 360
    // Artwork goes through the cache that keeps the decoded frame. Qt holds
    // unreferenced pixmaps against a 2MB budget, so a row scrolled back into
    // view was decoded again — see ThumbImageProvider. Only http sources: a
    // local file or a data: url is already cheap and Image handles it.
    function art(url) {
        const u = url || ""
        if (u.length === 0) return ""
        return u.startsWith("http") ? "image://thumb/" + u : u
    }
    readonly property int rowPx:  thumbQuality === "low" ? 90
                                : thumbQuality === "high" ? 360 : 180
    // Where a view's top goes when its origin moves, or NaN to leave contentY. A
    // view with its header inside keeps it at negative content y, so header reflow
    // moves originY while row 0 stays at 0. Writing contentY ends a flick in Qt (even
    // the same value), and early in a fling from the top it snaps back to the start,
    // so while `driven` (user dragging/flinging) nothing is written.
    function originHold(driven, atTop, base, originY, delta) {
        if (driven) return NaN
        if (atTop) return originY
        // the delta is owed only to a viewport looking AT the header; the rows
        // below it never moved
        if (base < 0) return Math.max(originY, base + delta)
        return NaN
    }

    // Without the app's settings — a QML test that builds a slider, which
    // reads the device grid here — the defaults stand
    readonly property bool hasSettings: typeof Settings !== "undefined" && Settings !== null
    function refresh() {
        if (!hasSettings) return
        growth = Number(Settings.uiGet("tileGrowth", 4))
        thumbQuality = String(Settings.uiGet("thumbQuality", "medium"))
    }
    Component.onCompleted: refresh()
    Connections {
        target: GridUi.hasSettings ? Settings : null
        ignoreUnknownSignals: true
        function onChanged() { GridUi.refresh() }
    }
}
