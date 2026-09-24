import QtQuick
import "../barstyles"
import "../.."

TransportButton {
    required property var host
    which: host.type === "playdisc" ? "play" : host.type
    // Any of the three may ask for a disc, since some players draw the whole
    // transport as discs; `playdisc` is a play that carries one without
    // saying.
    disc: host.type === "playdisc" || host.doc.disc === true
    role: host.doc.face || "accent"
    size: Theme.ctl(host.doc.size || 28)
    glyphSize: host.doc.glyph || Math.round((host.doc.size || 28) * 0.62)
    // a pill, when the document gives it a width and a height of its own
    pillW: host.doc.w > 0 ? Theme.ctl(host.doc.w) : 0
    pillH: host.doc.h > 0 ? Theme.ctl(host.doc.h) : 0
}
