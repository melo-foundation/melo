import QtQuick
import "../barstyles"
import "../.."

NpBarScrub {
    required property var host
    // a fixed scrub may fit the bar: as wide as the bar less a margin each
    // side, up to a most
    implicitWidth: host.doc.fitMax !== undefined
                   ? Math.min((host.layout ? host.layout.width : 0) - 2 * (host.doc.fitMargin || 0), host.doc.fitMax)
                   : (host.doc.w || 200)
    implicitHeight: host.doc.h !== undefined ? host.doc.h : 24
    trackH: host.doc.track !== undefined ? host.doc.track : 6
    hoverH: host.doc.hover !== undefined ? host.doc.hover : trackH + 2
    // the theme squares every seek bar; round, the layout says what corner
    trackRadius: Theme.scrubberShape === "square" ? 0 : host.doc.radius !== undefined ? host.doc.radius : -1
    showTimes: false                   // a time is its own element
    showBubble: host.doc.bubble !== false
    alignBottom: host.doc.edge === true
    trackRole: host.doc.trackRole || "scrubberTrack"
    glide: host.doc.glide === true
    holdAnims: host.bar ? host.bar.holdAnims === true : false
}
