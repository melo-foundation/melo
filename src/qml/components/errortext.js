.pragma library

// The words every failure shows: what happened, then what to do. The backend's
// own line never shows; it goes to the report and the log. Each answer is
// { text, fix, report }: `fix` the one action that helps ("retry", "settings"
// or ""), `report` true only for a failure melo cannot explain.

// yt-dlp's "Unable to download" alone names no network cause; its urlopen error does
const NETWORK = /timed? ?out|timeout|fetch failed|network|getaddrinfo|ENOTFOUND|EAI_AGAIN|ECONN|ETIMEDOUT|EHOSTUNREACH|socket hang up|connection|unreachable|urlopen error|name resolution|temporary failure/i
const SERVER = /HTTP Error 5\d\d|status code 5\d\d|\b50[0-4]\b/i
const UNAVAILABLE = /video unavailable|this video is (private|unavailable|no longer)|private video|has been removed|been terminated|not available in your country|uploader has not made|blocked it|copyright|members[- ]only|join this channel|does not exist|no longer exists|playlist (is )?(private|unavailable)|album unavailable/i
const YTDLP_MISSING = /yt-dlp could not be downloaded/i
const DISK_FULL = /No space left|ENOSPC|disk (is )?full|quota/i
const NO_WRITE = /Permission denied|EACCES|EPERM|read-only file system|EROFS/i
// a URL came back and googlevideo refused it (streams.ts REFUSED_STREAM)
const REFUSED = /refused the stream/i

function classOf(raw) {
    const s = String(raw || "")
    if (YTDLP_MISSING.test(s)) return "ytdlp"
    if (REFUSED.test(s)) return "refused"
    if (UNAVAILABLE.test(s)) return "unavailable"
    if (DISK_FULL.test(s)) return "disk"
    if (NO_WRITE.test(s)) return "nowrite"
    if (SERVER.test(s)) return "server"
    if (NETWORK.test(s)) return "network"
    return "unknown"
}

const CONNECTION = "Check your connection and try again."
// where no Try again button follows
const CONNECTION_ONLY = "Check your connection."
const SERVER_TEXT = "YouTube had a problem. Try again."
const NO_ANSWER = "YouTube didn't answer. " + CONNECTION
const YTDLP_TEXT = "yt-dlp didn't download. " + CONNECTION
const STALE_TEXT = "yt-dlp is out of date."
const UNAVAILABLE_TEXT = "YouTube says this video is unavailable."
const REFUSED_TEXT = "YouTube refused this track's stream. Try again."
const DISK_TEXT = "The disk is full. Free some space."
const NO_WRITE_TEXT = "melo can't write to the download folder. Pick another one in Settings."

function out(text, fix, report) { return { text: text, fix: fix || "", report: report === true } }

// ---- the playing track (PlayFailDialog) ----
// `cause`: PlayerState.failCause; `reason`: the sidecar's line; `stale`: the
// sidecar said a newer yt-dlp would likely play it; `nightly`: yt-dlp is on the
// nightly channel already, so "update" (the switch to it) is never offered.
function play(cause, reason, stale, nightly) {
    const t = playText(cause, reason, stale)
    if (nightly && t.fix === "update") t.fix = "retry"
    return t
}
function playText(cause, reason, stale) {
    // the wall's words are the sidecar's own (streams.ts WALL_MESSAGES), one per identity
    if (cause === "guestWall") return out(reason || "YouTube is blocking guest playback from your network.", "browser")
    if (cause === "browserWall")
        return out(reason || "YouTube is blocking playback from your network.",
                   /yt-dlp nightly/.test(reason) ? "update" : "retry")
    if (cause === "dropped")
        return out("The connection to YouTube dropped. Try again.", "retry")
    if (cause === "network") return out(NO_ANSWER, "retry")
    if (stale) return out(STALE_TEXT, "update")
    switch (classOf(reason)) {
    case "ytdlp": return out(YTDLP_TEXT, "retry")
    case "unavailable": return out(UNAVAILABLE_TEXT, "skip")
    case "refused": return out(REFUSED_TEXT, "retry")
    case "server": return out(SERVER_TEXT, "retry")
    case "network": return out(NO_ANSWER, "retry")
    }
    return out("This track didn't load.", "retry", true)
}

// ---- bars ----
function search(raw) {
    switch (classOf(raw)) {
    case "network": return out("Search didn't load. " + CONNECTION, "retry")
    case "server": return out("Search didn't load. " + SERVER_TEXT, "retry")
    }
    return out("Search didn't load.", "retry", true)
}

function download(raw) {
    switch (classOf(raw)) {
    case "ytdlp": return out(YTDLP_TEXT, "retry")
    case "unavailable": return out(UNAVAILABLE_TEXT, "")
    case "network": return out("The download stopped. " + CONNECTION, "retry")
    case "server": return out("The download stopped. " + SERVER_TEXT, "retry")
    case "disk": return out(DISK_TEXT, "")
    case "nowrite": return out(NO_WRITE_TEXT, "settings")
    }
    return out("The download failed.", "retry", true)
}

function radio(raw) {
    switch (classOf(raw)) {
    case "network": return out("The radio didn't start. " + CONNECTION_ONLY, "")
    case "server": return out("The radio didn't start. YouTube had a problem.", "")
    }
    return out("The radio didn't start.", "", true)
}

// a backend call that failed outside any page; null where another surface already says it
function rpc(what) {
    if (what === "sidecar" || what === "initialize" || what === "search") return null
    if (String(what).indexOf("plugins/") === 0) return out("The plugin change didn't go through.", "", true)
    return out("melo's backend didn't answer.", "", true)
}

// ---- in the page ----
function home(raw) {
    switch (classOf(raw)) {
    case "network": return out("Home didn't load. " + CONNECTION, "retry")
    case "server": return out("Home didn't load. " + SERVER_TEXT, "retry")
    }
    return out("Home didn't load.", "retry", true)
}

function playlist(raw) {
    switch (classOf(raw)) {
    case "unavailable": return out("YouTube says this playlist is unavailable.", "")
    case "network": return out("The playlist didn't load. " + CONNECTION, "retry")
    case "server": return out("The playlist didn't load. " + SERVER_TEXT, "retry")
    }
    return out("The playlist didn't load.", "retry", true)
}

function playlistSync(raw) {
    switch (classOf(raw)) {
    case "network": return out("The playlist didn't sync. " + CONNECTION, "retry")
    case "server": return out("The playlist didn't sync. " + SERVER_TEXT, "retry")
    }
    return out("The playlist didn't sync.", "retry", true)
}

// `browser`: its label ("Firefox")
function cookieImport(raw, browser) {
    const s = String(raw || ""), b = browser || "the browser"
    if (/could not find|no such file|not found|doesn't exist|does not exist|unsupported browser/i.test(s))
        return out("No " + b + " cookies were found. Pick the browser you use YouTube in.", "")
    if (/locked|could not copy|in use|Permission denied/i.test(s))
        return out("Close " + b + ", then import again.", "")
    if (/keyring|secretstorage|kwallet|decrypt|DPAPI|password/i.test(s))
        return out(b + "'s cookies are locked. Unlock your keyring or wallet, then import again.", "")
    return out("The import from " + b + " failed.", "", true)
}

function tagging(raw) {
    const s = String(raw || "")
    if (/api[_ ]?key|invalid key|401|403/i.test(s)) return out("Last.fm refused the API key. Check the key.", "")
    switch (classOf(s)) {
    case "network": return out("The tag services didn't answer. " + CONNECTION_ONLY, "")
    case "server": return out("The tag services had a problem.", "")
    }
    return out("Tagging failed.", "", true)
}

// the metadata editor's Replace… (sidecar library.ts)
function metadataFile(raw) {
    const s = String(raw || "")
    if (/file not found/i.test(s)) return out("That file can't be found.", "")
    if (/not an audio file/i.test(s)) return out("That isn't an audio file.", "")
    if (/no download folder/i.test(s)) return out("Set a download folder in Settings first.", "settings")
    if (/cannot be read/i.test(s)) return out("That file can't be read.", "")
    if (DISK_FULL.test(s)) return out(DISK_TEXT, "")
    if (NO_WRITE.test(s)) return out(NO_WRITE_TEXT, "settings")
    return out("The replacement didn't go through.", "", true)
}

function metadataLink(raw) {
    const s = String(raw || "")
    if (/not a YouTube link/i.test(s)) return out("That isn't a YouTube link.", "")
    if (/already its video/i.test(s)) return out("A YouTube track is already linked to its video.", "")
    return out("The link didn't save.", "", true)
}

// the metadata editor's Lookup: words only, an empty answer is no failure
function lookup(raw) {
    switch (classOf(raw)) {
    case "network": return "The lookup didn't answer. " + CONNECTION_ONLY
    case "server": return "The lookup service had a problem."
    }
    return "No match found."
}

// a plugin's state (sidecar plugins); Report only for melo's own plugins
// (MELO_PLUGINS): any other goes to its own author
const MELO_PLUGINS = ["soundcloud", "discord-presence"]
function plugin(p) {
    if (!p || (p.state !== "error" && p.state !== "crashed")) return null
    const text = p.state === "crashed" ? "This plugin kept crashing and was stopped." : "This plugin didn't start."
    return out(text, "", MELO_PLUGINS.indexOf(p.id) >= 0)
}
