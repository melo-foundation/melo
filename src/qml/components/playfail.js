.pragma library
.import "accounts.js" as Accounts

// The answers a failed track offers, by PlayerState.failCause, in button order.
// `choices`: the signed-in browsers "Use browser account" found, when several.
function actionsFor(cause, choices) {
    switch (cause) {
    case "guestWall":
        if (choices && choices.length > 1)
            return choices.map((b) => "browser:" + b).concat(["skip"])
        return ["browser", "retry", "skip"]
    case "browserWall": return ["update", "retry", "skip"]
    case "signin": return ["signin", "skip"]
    case "": return []
    default: return ["retry", "skip"]   // network, other
    }
}

function labelFor(action, busy) {
    if (action.indexOf("browser:") === 0) return Accounts.browserLabel(action.slice(8))
    switch (action) {
    case "browser": return busy ? "Checking…" : "Use browser account"
    case "update": return "Update yt-dlp"
    case "signin": return "Sign in again"
    case "retry": return "Retry"
    case "skip": return "Skip"
    }
    return action
}
