// Shortcut plumbing: ui.shortcuts stores bindings in DOM key-code form
// ("ctrl+shift+KeyL"). toQt() converts to QKeySequence strings for QML Shortcut; fromKeyEvent()
// encodes a recorded QML key event back into DOM format.
.pragma library

var DEFAULTS = {
    toggleSearch: "ctrl+KeyF",
    playPause: "Space",
    rewind: "ArrowLeft",
    forward: "ArrowRight",
    nextTrack: "KeyN",
    prevTrack: "KeyP",
    prevTrackAlt: "Backspace",
    deleteTrack: "shift+Delete",
    addToLibrary: "KeyL",
    bgPresetNext: "BracketRight",
    bgPresetPrev: "BracketLeft",
    // gesture-bound by default (double-click, Escape); no key unless the
    // user records one, so an empty default is the binding, not a hole
    toggleCompact: "",
    toggleMaximize: "",
    // The chrome buttons. Empty for the same reason as the two above: a
    // default key here would take one away from the user. They are commands so
    // a plugin can take them over (InterceptMap.offer() lives in the command
    // switch), which also makes them bindable.
    toggleQueue: "",
    toggleEq: "",
    toggleVisualizer: "",
    openSettings: "",
    togglePin: "",
}

var ORDER = ["toggleSearch", "playPause", "rewind", "forward", "nextTrack",
             "prevTrack", "prevTrackAlt", "deleteTrack", "addToLibrary",
             "bgPresetNext", "bgPresetPrev",
             "toggleCompact", "toggleMaximize",
             "toggleQueue", "toggleEq", "toggleVisualizer",
             "openSettings", "togglePin"]

var LABELS = {
    toggleSearch: "Toggle search",
    playPause: "Play / Pause",
    rewind: "Rewind 5s",
    forward: "Forward 5s",
    nextTrack: "Next track",
    prevTrack: "Previous track",
    prevTrackAlt: "Previous track (alt)",
    deleteTrack: "Delete library track",
    addToLibrary: "Add to library",
    bgPresetNext: "Next BG preset",
    bgPresetPrev: "Prev BG preset",
    toggleCompact: "Compact mode",
    toggleMaximize: "Maximize / restore",
    toggleQueue: "Queue panel",
    toggleEq: "Equalizer",
    toggleVisualizer: "Visualizer",
    openSettings: "Settings",
    togglePin: "Always on top",
}

function merged(saved) {
    const out = {}
    for (const k in DEFAULTS) out[k] = (saved && saved[k]) ? saved[k] : DEFAULTS[k]
    if (saved)
        for (const k in saved)
            if (!(k in DEFAULTS) && saved[k]) out[k] = saved[k]
    return out
}

function codeToQtKey(code) {
    if (code.indexOf("Key") === 0) return code.slice(3)
    if (code.indexOf("Digit") === 0) return code.slice(5)
    const map = {
        ArrowLeft: "Left", ArrowRight: "Right", ArrowUp: "Up", ArrowDown: "Down",
        BracketLeft: "[", BracketRight: "]", Space: "Space", Backspace: "Backspace",
        Delete: "Del", Enter: "Return", Escape: "Esc", Tab: "Tab",
        Minus: "-", Equal: "=", Comma: ",", Period: ".", Slash: "/",
        Semicolon: ";", Quote: "'", Backquote: "`", Backslash: "\\",
    }
    return map[code] || code
}

// "ctrl+shift+KeyL" -> "Ctrl+Shift+L"
function toQt(seq) {
    if (!seq) return ""
    const parts = seq.split("+")
    const out = []
    for (const p of parts) {
        if (p === "ctrl") out.push("Ctrl")
        else if (p === "shift") out.push("Shift")
        else if (p === "alt") out.push("Alt")
        else if (p === "meta") out.push("Meta")
        else out.push(codeToQtKey(p))
    }
    return out.join("+")
}

// display formatting
function format(seq) {
    if (!seq) return ""
    return seq.split("+").map((p) => {
        if (p === "ctrl") return "Ctrl"
        if (p === "shift") return "Shift"
        if (p === "alt") return "Alt"
        if (p === "meta") return "Meta"
        if (p.indexOf("Key") === 0) return p.slice(3)
        if (p.indexOf("Digit") === 0) return p.slice(5)
        if (p === "ArrowLeft") return "←"
        if (p === "ArrowRight") return "→"
        if (p === "ArrowUp") return "↑"
        if (p === "ArrowDown") return "↓"
        return p
    }).join(" + ")
}

// QML Keys event -> DOM-format string; null for bare modifiers/unknown keys
function fromKeyEvent(event) {
    let k = event.key
    if (k === Qt.Key_Control || k === Qt.Key_Shift || k === Qt.Key_Alt
        || k === Qt.Key_Meta) return null

    // Qt reports the SHIFTED symbol as the key (Shift+1 = Key_Exclam,
    // Shift+[ = Key_BraceLeft) — and depending on platform the Shift
    // modifier flag may or may not accompany it. Normalize back to the
    // physical key UNCONDITIONALLY; a shifted symbol implies shift.
    let symbolShift = false
    {
        const shifted = {}
        shifted[Qt.Key_Exclam] = Qt.Key_1; shifted[Qt.Key_At] = Qt.Key_2
        shifted[Qt.Key_NumberSign] = Qt.Key_3; shifted[Qt.Key_Dollar] = Qt.Key_4
        shifted[Qt.Key_Percent] = Qt.Key_5; shifted[Qt.Key_AsciiCircum] = Qt.Key_6
        shifted[Qt.Key_Ampersand] = Qt.Key_7; shifted[Qt.Key_Asterisk] = Qt.Key_8
        shifted[Qt.Key_ParenLeft] = Qt.Key_9; shifted[Qt.Key_ParenRight] = Qt.Key_0
        shifted[Qt.Key_BraceLeft] = Qt.Key_BracketLeft
        shifted[Qt.Key_BraceRight] = Qt.Key_BracketRight
        shifted[Qt.Key_Less] = Qt.Key_Comma; shifted[Qt.Key_Greater] = Qt.Key_Period
        shifted[Qt.Key_Question] = Qt.Key_Slash; shifted[Qt.Key_Colon] = Qt.Key_Semicolon
        shifted[Qt.Key_QuoteDbl] = Qt.Key_Apostrophe
        shifted[Qt.Key_AsciiTilde] = Qt.Key_QuoteLeft
        shifted[Qt.Key_Underscore] = Qt.Key_Minus; shifted[Qt.Key_Plus] = Qt.Key_Equal
        shifted[Qt.Key_Bar] = Qt.Key_Backslash
        if (shifted[k] !== undefined) { k = shifted[k]; symbolShift = true }
    }

    let code = null
    if (k >= Qt.Key_A && k <= Qt.Key_Z)
        code = "Key" + String.fromCharCode(65 + (k - Qt.Key_A))
    else if (k >= Qt.Key_0 && k <= Qt.Key_9)
        code = "Digit" + String.fromCharCode(48 + (k - Qt.Key_0))
    else {
        const map = {}
        map[Qt.Key_Left] = "ArrowLeft"; map[Qt.Key_Right] = "ArrowRight"
        map[Qt.Key_Up] = "ArrowUp"; map[Qt.Key_Down] = "ArrowDown"
        map[Qt.Key_Space] = "Space"; map[Qt.Key_Backspace] = "Backspace"
        map[Qt.Key_Delete] = "Delete"; map[Qt.Key_Return] = "Enter"
        map[Qt.Key_Enter] = "Enter"; map[Qt.Key_Tab] = "Tab"
        map[Qt.Key_BracketLeft] = "BracketLeft"; map[Qt.Key_BracketRight] = "BracketRight"
        map[Qt.Key_Minus] = "Minus"; map[Qt.Key_Equal] = "Equal"
        map[Qt.Key_Comma] = "Comma"; map[Qt.Key_Period] = "Period"
        map[Qt.Key_Slash] = "Slash"; map[Qt.Key_Semicolon] = "Semicolon"
        map[Qt.Key_Apostrophe] = "Quote"; map[Qt.Key_QuoteLeft] = "Backquote"
        map[Qt.Key_Backslash] = "Backslash"
        code = map[k] || null
    }
    if (!code) return null

    const mods = []
    if (event.modifiers & Qt.ControlModifier) mods.push("ctrl")
    if ((event.modifiers & Qt.ShiftModifier) || symbolShift) mods.push("shift")
    if (event.modifiers & Qt.AltModifier) mods.push("alt")
    if (event.modifiers & Qt.MetaModifier) mods.push("meta")
    return mods.concat([code]).join("+")
}
