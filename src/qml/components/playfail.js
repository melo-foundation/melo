.pragma library
.import "accounts.js" as Accounts
.import "errortext.js" as ErrorText

// The answers a failed track offers, in button order: the fix errortext.js
// names first, then the others; Report… only where the cause is unknown.
// `choices`: the signed-in browsers "Use browser account" found, when several;
// `nightly`: yt-dlp is on the nightly channel already.
function actionsFor(cause, choices, reason, stale, nightly) {
    if (cause === "") return []
    if (cause === "guestWall" && choices && choices.length > 1)
        return choices.map((b) => "browser:" + b).concat(["skip"])
    const t = ErrorText.play(cause, reason, stale, nightly)
    const out = [t.fix]
    if (t.fix !== "retry") out.push("retry")
    if (t.fix !== "skip") out.push("skip")
    if (t.report) out.push("report")
    return out
}

function messageFor(cause, reason, stale) { return ErrorText.play(cause, reason, stale).text }

function labelFor(action, busy) {
    if (action.indexOf("browser:") === 0) return Accounts.browserLabel(action.slice(8))
    switch (action) {
    case "browser": return busy ? "Checking…" : "Use browser account"
    case "update": return "Use yt-dlp nightly"
    case "retry": return "Try again"
    case "skip": return "Skip"
    case "report": return "Report…"
    }
    return action
}
