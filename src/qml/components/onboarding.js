.pragma library

// First-run choices only; the rest of the wizard reuses the app's controls
// and lists.

// Mood names offered as one-tap new profiles; each profile is its own guest
// session with its own suggestions. Names already taken (any case) are
// skipped, at most three are offered, and none repeat.
const MOODS = ["Focus", "Chill", "Gym", "Sleep", "Party", "Study"]

function moodSuggestions(profiles) {
    const taken = (profiles || []).map((p) => String(p).toLowerCase())
    return MOODS.filter((m) => taken.indexOf(m.toLowerCase()) < 0).slice(0, 3)
}

// How the crossfade reads beside its slider, as the settings window reads it.
function crossfadeLabel(seconds) {
    return seconds === 0 ? "Off" : seconds.toFixed(1) + "s"
}
