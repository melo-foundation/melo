.pragma library

// The identity list shared by the title bar menu and the settings window, so
// the two cannot disagree. An identity is one of:
//   a browser  — melo reads its cookies live and keeps no copy of the session
//   a profile  — a guest cookie jar melo owns
//   no account — no cookies; always listed, and the whole list when nothing is set up
// Browsers list only when installed (cookies/browsers), plus the one in use even
// if detection missed it. `status` fills in from cookies/status, keyed
// statusKey(kind, id); the menu does not wait, as decrypting a store takes
// seconds. A saved profile name that no longer exists marks nothing.

function statusKey(kind, id) {
    return kind + ":" + id
}

function detailOf(st) {
    if (!st) return ""
    if (!st.signedIn) return "signed out"
    return st.account && st.account.name ? st.account.name : "signed in"
}

function entries(o) {
    const out = []
    const browsers = (o.browsers || []).slice()
    if (o.cookieSource === "browser" && o.browser && browsers.indexOf(o.browser) < 0)
        browsers.push(o.browser)
    const status = o.status || {}
    // being re-read: the answer from before is not shown as current
    const checking = o.checking || {}

    for (let i = 0; i < browsers.length; i++) {
        const id = browsers[i]
        const st = status[statusKey("browser", id)]
        const busy = checking[statusKey("browser", id)] === true
        const detail = busy ? "checking…" : detailOf(st)
        out.push({ kind: "browser", id: id, key: "browser:" + id, name: browserLabel(id),
                   label: browserLabel(id) + (detail ? " · " + detail : ""),
                   account: !busy && st && st.signedIn ? st.account : null,
                   active: o.cookieSource === "browser" && o.browser === id })
    }
    const profiles = o.profiles || []
    for (let i = 0; i < profiles.length; i++) {
        const id = profiles[i]
        const st = status[statusKey("guest", id)]
        // a guest profile is only worth a detail when it is signed in
        const detail = st && st.signedIn ? detailOf(st) : ""
        out.push({ kind: "guest", id: id, key: "guest:" + id, name: id,
                   label: id + (detail ? " · " + detail : ""),
                   account: st && st.signedIn ? st.account : null,
                   active: o.cookieSource === "guest" && o.cookieProfile === id })
    }
    const empty = out.length === 0
    out.push({ kind: "none", id: "none", key: "none:none", name: "No account", label: "No account", account: null,
               active: o.cookieSource === "none" || empty })
    return out
}

// Writes the identity's own key before the source; flipping the source first
// would, for one write, speak as the previously saved identity. Unchanged values
// are skipped because every identity write clears the sidecar's cookie caches.
function applyChoice(e, settings) {
    if (e.kind === "browser") {
        if (settings.browser !== e.id) settings.browser = e.id
        if (settings.cookieSource !== "browser") settings.cookieSource = "browser"
    } else if (e.kind === "guest") {
        if (settings.cookieProfile !== e.id) settings.cookieProfile = e.id
        if (settings.cookieSource !== "guest") settings.cookieSource = "guest"
    } else if (settings.cookieSource !== "none") {
        settings.cookieSource = "none"
    }
}

// Asks the sidecar who an identity is, naming it outright so the answer does
// not depend on a settings write having arrived. `host` has rpc(method, params,
// callback). `fresh` re-reads a browser's store, since logins change outside
// melo. `fail` is called on a request that returned no answer, so a row does not
// stay "checking".
function askStatus(host, kind, id, done, fresh, fail) {
    const p = kind === "browser" ? { source: "browser", browser: id } : { source: "guest", profile: id }
    if (fresh && kind === "browser") p.fresh = true
    const key = statusKey(kind, id)
    host.rpc("cookies/status", p, (r) => {
        if (!r || !r.ok || !r.result) { if (fail) fail(key); return }
        done(key, { signedIn: !!r.result.signedIn, account: r.result.account || null })
    })
}

function activeOf(list) {
    return (list || []).find((e) => e.active) || null
}

// the title bar: who you are when signed in, the identity's name otherwise
function titleOf(list) {
    const a = activeOf(list)
    if (!a) return "No account"
    return a.account && a.account.name ? a.account.name : a.name
}

function photoOf(list) {
    const a = activeOf(list)
    return a && a.account && a.account.photo ? a.account.photo : ""
}

// The ones yt-dlp knows, named as the settings window names them. An
// unfamiliar value is still a saved identity, shown as it stands.
const BROWSER_LABELS = {
    firefox: "Firefox", chrome: "Chrome", chromium: "Chromium",
    brave: "Brave", edge: "Edge",
}

function browserLabel(value) {
    return BROWSER_LABELS[value] || value || ""
}
