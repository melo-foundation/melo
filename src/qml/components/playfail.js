.pragma library

// The answers a failed track offers, by PlayerState.failCause, in button order.
function actionsFor(cause) {
    switch (cause) {
    case "guestWall": return ["browser", "retry", "skip"]
    case "browserWall": return ["update", "retry", "skip"]
    case "signin": return ["signin", "skip"]
    case "": return []
    default: return ["retry", "skip"]   // network, other
    }
}

function labelFor(action) {
    switch (action) {
    case "browser": return "Use browser account"
    case "update": return "Update yt-dlp"
    case "signin": return "Sign in again"
    case "retry": return "Retry"
    case "skip": return "Skip"
    }
    return action
}
