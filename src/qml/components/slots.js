// The Appearance page's slot rows, as pure functions of what SlotMap knows.
// Invariants (pinned in sidecar/plugin-js/slots-ui.test.ts):
//  1. A row is the slot's name, what draws it now, and the alternatives; no
//     explanatory sentence.
//  2. Only slots a plugin offers or that are already bound get a row.
//  3. melo's own chrome is always an option and always first (the way back);
//     Hidden is always last (destructive).
//  4. Nothing here reads SlotMap, so rows can be built in a test without a shell.
.pragma library

// Slot id -> what the user calls that part of the window. An id with no entry
// falls through to itself rather than vanishing, so a slot added to the C++
// catalog without a label here is visible and obviously unfinished.
var LABELS = {
    playerBar:  "Player bar",
    titleBar:   "Title bar",
    searchBar:  "Search bar",
    tabBar:     "Tabs",
    queuePanel: "Queue panel",
    home:       "Home",
    library:    "Library",
    search:     "Search",
    visualizer: "Visualizer",
    background: "Background",
    eq:         "Equaliser",
}

function label(id) { return LABELS[id] || id }

// entries: [{ id, bound, offers: [pluginId] }]
// names:   { pluginId: displayName }
function rows(entries, names, hiddenId) {
    var out = []
    if (!entries) return out
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        var offers = e.offers || []
        var bound = e.bound || ""
        // Nothing offers it and nothing is bound: no row.
        if (!offers.length && bound === "") continue
        var options = [{ value: "", label: "melo" }]
        for (var j = 0; j < offers.length; j++)
            options.push({ value: offers[j], label: (names && names[offers[j]]) || offers[j] })
        // A plugin that went away still holds its slot, and the row has to be
        // able to say so — otherwise the select shows a value that is not in
        // its own option list and reads as empty.
        if (bound !== "" && bound !== hiddenId && offers.indexOf(bound) < 0)
            options.push({ value: bound, label: ((names && names[bound]) || bound) + " (unavailable)" })
        options.push({ value: hiddenId, label: "Hidden" })
        out.push({ id: e.id, label: label(e.id), bound: bound, options: options })
    }
    return out
}
