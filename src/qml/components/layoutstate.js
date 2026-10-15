.pragma library

// The window layout melo reopens at start, from "layout" and "window.<kind>".
// get(key, fallback) reads a saved ui value; canPlace is window placement.
function plan(get, canPlace) {
    const l = get("layout", null)
    const s = l && typeof l === "object" ? l : ({})
    const mini = s.mini === true
    const windows = []
    for (const kind of ["queue", "vis", "video"]) {
        const p = get("window." + kind, null)
        // a kind that is not detached shows under the bar instead
        if (p && p.open === true && (p.detached === true || !canPlace)) windows.push(kind)
    }
    return {
        mini: mini,
        maximized: !mini && s.maximized === true,
        miniAt: mini && typeof s.miniX === "number" && typeof s.miniY === "number" ? { x: s.miniX, y: s.miniY } : null,
        popup: mini && canPlace && (s.popup === "queue" || s.popup === "vis") ? s.popup : "",
        windows: windows
    }
}

// What the attached popup is set to show: "vis" (the visualizer or the video), "queue" or "".
function popupOf(miniVisWanted, showPanel, queueDetached) {
    if (miniVisWanted) return "vis"
    return showPanel && !queueDetached ? "queue" : ""
}

// The fields to save for the state now; null while nothing should be saved.
function record(st) {
    if (!st.recording || st.toggling) return null
    const f = { mini: st.miniPlayer }
    if (st.miniPlayer) f.popup = st.popup
    // hidden and minimised are not a layout: closing melo hides main
    else if (st.visibility === "windowed" || st.visibility === "maximized") f.maximized = st.visibility === "maximized"
    return f
}

// A saved place on the screen under its centre, clamped into it; null on none.
// screens: [{ x, y, width, height }]
function onScreen(x, y, w, h, screens) {
    const cx = x + w / 2, cy = y + h / 2
    for (const s of screens) {
        if (cx >= s.x && cx < s.x + s.width && cy >= s.y && cy < s.y + s.height)
            return { x: Math.max(s.x, Math.min(x, s.x + s.width - w)), y: Math.max(s.y, Math.min(y, s.y + s.height - h)) }
    }
    return null
}

// How main starts at its saved place: X11 places it before it maps, KWin on
// Wayland moves it after its first frame and maximises it in that step; a
// maximised main maps maximised wherever nothing places it first.
function mainStart(maximized, place, x11, kwin) {
    const byKwin = maximized && !!place && !x11 && kwin
    return { preplace: x11 ? place : null, maximizeNow: maximized && !byKwin, maximizeByKwin: byKwin }
}
