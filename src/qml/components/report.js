.pragma library

// Report…: the error's details to a local file (SettingsStore.writeReport),
// that folder opened, and the public tracker's bug form titled by the error's
// kind. The URL carries the title only; a detail can name a video or a path.

const TITLES = {
    playback: "Playback problem",
    error: "Error message",
    backend: "Backend not running",
    node: "Node.js download failed",
    ytdlp: "yt-dlp problem",
    download: "Download failed",
    plugin: "Plugin problem",
    gstreamer: "Missing GStreamer elements",
    blur: "Window blur not detected",
    home: "Home failed to load",
    playlist: "Playlist failed to load",
    cookies: "Cookie import failed",
    tagging: "Tagging failed",
    metadata: "Metadata editor problem",
}

// `sub`: a cause, a code or a plugin id; never free text
function title(kind, sub) {
    return (TITLES[kind] || "Problem") + (sub !== undefined && sub !== "" ? " (" + sub + ")" : "")
}

function issueUrl(kind, sub) {
    return "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml"
        + "&title=" + encodeURIComponent(title(kind, sub))
}

// `settings` has writeReport(kind, details); `open` is Qt.openUrlExternally
// unless a test passes its own
function send(settings, kind, sub, details, open) {
    const go = open || ((u) => Qt.openUrlExternally(u))
    const r = settings && settings.writeReport ? settings.writeReport(kind, details || {}) : null
    if (r && r.folder) go(r.folder)
    go(issueUrl(kind, sub))
    return r
}
