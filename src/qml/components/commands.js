// Gesture catalog for the Shortcuts tab. Ids and labels match sidecar
// GESTURE_IDS. Occupancy writes go through applyGesture so one
// command taking playerBar.doubleClick cannot drag compact.escape with it.
.pragma library

var GESTURES = ["playerBar.doubleClick", "compact.escape", "titleBar.doubleClick"]

var LABELS = {
    "playerBar.doubleClick": "Player bar double-click",
    "compact.escape": "Escape in compact",
    "titleBar.doubleClick": "Title bar double-click",
}

var GESTURE_DEFAULTS = {
    "playerBar.doubleClick": "toggleCompact",
    "compact.escape": "toggleCompact",
    "titleBar.doubleClick": "toggleMaximize",
}

function applyGesture(gestures, gestureId, commandId) {
    const out = {}
    for (const k in gestures) if (gestures[k] !== commandId) out[k] = gestures[k]
    if (commandId) out[gestureId] = commandId
    else delete out[gestureId]
    return out
}

// Write-once: sequential applyGesture for the same command strips earlier
// keys. Default on toggleCompact must keep playerBar.doubleClick AND
// compact.escape.
function defaultGestures(gestures, commandId) {
    const out = {}
    for (const k in gestures) out[k] = gestures[k]
    for (let i = 0; i < GESTURES.length; i++) {
        const gid = GESTURES[i]
        if (GESTURE_DEFAULTS[gid] === commandId)
            out[gid] = commandId
    }
    return out
}

// NONE is stored, not absent. A missing key means "nobody has said anything
// about this gesture" and falls back to the builtin default, so deleting a key
// hands the gesture straight back to the command it was taken from.
var NONE = "none"

// This command holds no gesture: every gesture it holds becomes unbound.
function clearOccupants(gestures, commandId) {
    const out = {}
    for (const k in gestures) out[k] = gestures[k]
    for (let i = 0; i < GESTURES.length; i++) {
        const gid = GESTURES[i]
        if (out[gid] === commandId) out[gid] = NONE
    }
    return out
}

function hasGestureDefault(commandId) {
    for (let i = 0; i < GESTURES.length; i++)
        if (GESTURE_DEFAULTS[GESTURES[i]] === commandId) return true
    return false
}

function hijackCommandId(plugin) {
    if (!plugin || !plugin.id || !plugin.commands) return ""
    for (let i = 0; i < plugin.commands.length; i++)
        if (plugin.commands[i] && plugin.commands[i].id === "toggleGroup")
            return plugin.id + ".toggleGroup"
    return ""
}

function playerBarHijacked(gestures, plugin) {
    const cmd = hijackCommandId(plugin)
    if (!cmd) return false
    const occ = (gestures && gestures["playerBar.doubleClick"])
                || GESTURE_DEFAULTS["playerBar.doubleClick"]
    return occ === cmd
}

function setPlayerBarHijack(gestures, plugin, on) {
    const cmd = hijackCommandId(plugin)
    if (!cmd) return gestures
    if (on) return applyGesture(gestures, "playerBar.doubleClick", cmd)
    const out = {}
    for (const k in gestures) out[k] = gestures[k]
    const cur = out["playerBar.doubleClick"] || GESTURE_DEFAULTS["playerBar.doubleClick"]
    if (cur !== cmd) return gestures
    out["playerBar.doubleClick"] = GESTURE_DEFAULTS["playerBar.doubleClick"]
    return out
}

function commandRows(order, labels, pluginList) {
    const out = []
    for (let i = 0; i < order.length; i++)
        out.push({ id: order[i], label: labels[order[i]] })
    if (!pluginList) return out
    for (let i = 0; i < pluginList.length; i++) {
        const p = pluginList[i]
        const cmds = (p && p.commands) || []
        if (!cmds.length) continue
        for (let j = 0; j < cmds.length; j++) {
            const cmd = cmds[j]
            out.push({ id: p.id + "." + cmd.id, label: cmd.label })
        }
    }
    return out
}
