// The Plugins tab's grant rows, as pure functions of one plugin's PluginInfo.
// Invariants (tested in tests/qml/tst_plugingrants.qml):
//  1. Every write is a partial patch (`{ ui }`, `{ rawNetwork }` or
//     `{ intercept }`); the sidecar merges `{ ...grants, ...patch }`, and a full
//     object rebuilt from a stale row reverts the two untouched fields.
//  2. Nothing is cached here or on the row: the Repeater's JS-array model
//     recreates every delegate on refresh, so a row-local lock is cleared by any
//     other plugin's refresh. Each patch derives only from the PluginInfo handed
//     in, so one plugin's click cannot move another's grants.
//  3. patch() never mutates its input; the intercept list is copied first.
.pragma library

function has(xs, v) {
    if (!xs || !xs.length) return false
    for (let i = 0; i < xs.length; i++) if (xs[i] === v) return true
    return false
}

function interceptGrants(p) {
    const ic = (p && p.grants && p.grants.intercept) || []
    return Array.isArray(ic) ? ic : []
}

// ui / rawNetwork / each declared intercept — labels are catalog ids, not
// invented copy. ⚠ text is looked up from sidecar permissionWarnings.
function rows(p) {
    const out = []
    if (!p) return out
    // ui is granted by enabling the plugin (⚠ on that row), so it has no
    // grant row; nested here it reads as a second plugin.
    const perms = p.permissions || {}
    if (perms.rawNetwork)
        out.push({ kind: "rawNetwork", name: "rawNetwork" })
    const ic = perms.intercept || []
    for (let i = 0; i < ic.length; i++)
        out.push({ kind: "intercept", name: String(ic[i]), action: String(ic[i]) })
    return out
}

function warning(p, kind, action) {
    const ws = (p && p.warnings) || []
    let needle = ""
    if (kind === "ui") needle = "inside melo"
    else if (kind === "rawNetwork") needle = "not limited"
    else needle = String(action || "")
    if (!needle.length) return ""
    for (let i = 0; i < ws.length; i++)
        if (String(ws[i]).indexOf(needle) >= 0) return "⚠ " + ws[i]
    return ""
}

function checked(p, kind, action) {
    const g = (p && p.grants) || {}
    if (kind === "ui") return !!g.ui
    if (kind === "rawNetwork") return !!g.rawNetwork
    return has(interceptGrants(p), action)
}

// One key only. `intercept` is the exception the merge forces: the server
// replaces that array wholesale, so the patch is this plugin's current list
// plus (or minus) the action just clicked.
function patch(p, kind, on, action) {
    if (kind === "ui") return { ui: !!on }
    if (kind === "rawNetwork") return { rawNetwork: !!on }
    const cur = interceptGrants(p)
    const ic = []
    for (let i = 0; i < cur.length; i++) ic.push(cur[i])
    let at = -1
    for (let j = 0; j < ic.length; j++) if (ic[j] === action) { at = j; break }
    if (on && at < 0) ic.push(action)
    if (!on && at >= 0) ic.splice(at, 1)
    return { intercept: ic }
}

// The enable switch stays clickable when a plugin is already on, even in
// error, so the user can turn it off. An invalid plugin that is off stays
// off: turning it on would fail again.
function enableToggleEnabled(p) {
    if (!p) return false
    if (p.state !== "error") return true
    return !!p.enabled
}
