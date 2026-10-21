.pragma library

// Report…: the error's details to a local file (SettingsStore.writeReport,
// with README.txt beside it), that file shown in the file manager, and the
// public tracker's bug form opened, titled by the error's kind. The form gets
// the words melo showed, the version and the system; any other detail can
// name a video or a path, so it stays in the file.

const ISSUE_FORM = "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml"

const TITLES = {
    playback: "Playback problem",
    error: "Backend call failed",
    backend: "Backend not running",
    download: "Download failed",
    search: "Search failed",
    radio: "Radio failed to start",
    plugin: "Plugin problem",
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

// `said`: the words the error showed; `info`: writeReport's { version, system }
function issueUrl(kind, sub, said, info) {
    let u = ISSUE_FORM + "&title=" + encodeURIComponent(title(kind, sub))
    if (said) u += "&what=" + encodeURIComponent("melo said: " + said)
    if (info && info.version) u += "&version=" + encodeURIComponent(info.version)
    if (info && info.system) u += "&system=" + encodeURIComponent(info.system)
    return u
}

// Main.qml sets it to WindowCtl.showFile; unset (a test), the folder opens
let showFile = null
function setShowFile(fn) { showFile = fn }

// `settings` has writeReport(kind, details); `open` is Qt.openUrlExternally
// unless a test passes its own. `details.message` is the words the error showed.
function send(settings, kind, sub, details, open) {
    const go = open || ((u) => Qt.openUrlExternally(u))
    const d = details || {}
    const r = settings && settings.writeReport ? settings.writeReport(kind, d) : null
    if (r && r.path && showFile) showFile(r.path)
    else if (r && r.folder) go(r.folder)
    go(issueUrl(kind, sub, d.message, r))
    return r
}
