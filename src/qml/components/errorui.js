.pragma library

// An error's buttons in the one order melo uses: Report… on the left, the
// other answers, the main one on the right. `actions` lists the main one first
// (the one Enter takes), then the others; "report" may sit anywhere in it.
function ordered(actions) {
    const list = actions || []
    const report = list.filter((a) => a.id === "report")
    const rest = list.filter((a) => a.id !== "report")
    if (!rest.length) return report
    return report.concat(rest.slice(1), [rest[0]])
}

// the one Enter takes: the first that is not Report…
function primaryOf(actions) {
    const rest = (actions || []).filter((a) => a.id !== "report")
    return rest.length ? rest[0].id : ""
}

// WCAG contrast of two colours (QML color values)
function lum(c) {
    const lin = (x) => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4)
    return lin(c.r) * 0.2126 + lin(c.g) * 0.7152 + lin(c.b) * 0.0722
}
function contrast(a, b) {
    const x = lum(a), y = lum(b)
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}

// The main button's words: white, or near-black where white reads below 4.5:1
// on that accent (#308cc6, the default system accent, gives white 3.7).
function inkOn(bg) {
    const white = Qt.rgba(1, 1, 1, 1), dark = Qt.rgba(0.08, 0.08, 0.08, 1)
    return contrast(white, bg) >= 4.5 || contrast(white, bg) >= contrast(dark, bg) ? white : dark
}

// The alert glyph: the danger colour, moved toward black on a light face (white
// on a dark one) in tenths until it reaches 3:1.
function glyphOn(danger, face) {
    const toward = lum(face) > 0.18 ? 0 : 1
    let c = danger
    for (let i = 1; i <= 10 && contrast(c, face) < 3; i++) {
        const t = i / 10
        c = Qt.rgba(danger.r + (toward - danger.r) * t, danger.g + (toward - danger.g) * t,
                    danger.b + (toward - danger.b) * t, 1)
    }
    return c
}
