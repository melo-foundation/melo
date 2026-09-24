.pragma library

// What an empty home may claim. Names only a cause melo can tell from its
// settings; a false cause is worse than none. sendPlayback off is never named
// (YouTube still answers, generically); it only withdraws the "play something"
// advice. Order: no session first, then signed-in, then the default.

function emptyState(s) {
    if (!s || !s.loadedOnce) return null
    if (s.loading) return null
    // the error surface owns the message when there is an error
    if (s.error && s.error.length) return null
    if (s.count > 0) return null

    if (s.cookieSource === "none") return { line: "No session" }
    // YouTube serves an empty home when the account's watch history is
    // paused. A guest session does not produce this, so it is only claimed
    // when the session is actually signed in.
    if (s.signedIn) return { line: "Watch history is off", actions: ["history", "guest"] }
    if (!s.sendPlayback) return { line: "No recommendations" }
    return { line: "Play something to build suggestions" }
}
