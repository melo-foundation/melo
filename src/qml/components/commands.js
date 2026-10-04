// Gesture catalog for the Shortcuts tab. Ids and labels match sidecar
// GESTURE_IDS. A command holds at most one gesture, so its row shows what is bound.
.pragma library

var GESTURES = ["playerBar.doubleClick", "titleBar.doubleClick"]

var LABELS = {
    "playerBar.doubleClick": "Player bar double-click",
    "titleBar.doubleClick": "Title bar double-click",
}

var GESTURE_DEFAULTS = {
    "playerBar.doubleClick": "toggleCompact",
    "titleBar.doubleClick": "toggleMaximize",
}

// The command's other gesture goes: back to its default owner, or unbound when
// the command was that owner.
function applyGesture(gestures, gestureId, commandId) {
    const out = {}
    for (const k in gestures) out[k] = gestures[k]
    if (!commandId) { delete out[gestureId]; return out }
    for (let i = 0; i < GESTURES.length; i++) {
        const gid = GESTURES[i]
        if (gid === gestureId || occupant(out, gid) !== commandId) continue
        if (GESTURE_DEFAULTS[gid] === commandId) out[gid] = NONE
        else delete out[gid]
    }
    out[gestureId] = commandId
    return out
}

function defaultGestures(gestures, commandId) {
    for (let i = 0; i < GESTURES.length; i++)
        if (GESTURE_DEFAULTS[GESTURES[i]] === commandId)
            return applyGesture(gestures, GESTURES[i], commandId)
    return gestures
}

// NONE is stored, not absent. A missing key means "nobody has said anything
// about this gesture" and falls back to the builtin default, so deleting a key
// hands the gesture straight back to the command it was taken from.
var NONE = "none"

// Who holds a gesture: the stored binding, else the builtin default.
function occupant(gestures, gestureId) {
    return gestures && gestures.hasOwnProperty(gestureId) ? gestures[gestureId]
                                                         : GESTURE_DEFAULTS[gestureId]
}

// This command holds no gesture: every gesture it holds becomes unbound,
// defaults included.
function clearOccupants(gestures, commandId) {
    const out = {}
    for (const k in gestures) out[k] = gestures[k]
    for (let i = 0; i < GESTURES.length; i++) {
        const gid = GESTURES[i]
        if (occupant(out, gid) === commandId) out[gid] = NONE
    }
    return out
}

// The gesture a command holds, by its label; "\u2014" when it holds none.
function gestureLabel(gestures, commandId) {
    for (let i = 0; i < GESTURES.length; i++)
        if (occupant(gestures, GESTURES[i]) === commandId) return LABELS[GESTURES[i]]
    return "\u2014"
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
