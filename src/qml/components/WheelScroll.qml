import QtQuick

// Configurable wheel scrolling for a Flickable/ListView/GridView: overlays
// the view and handles ONLY wheel events (buttons/hover pass through).
// Speed comes from ui.scrollSpeed (rows per notch, row ~= 52px).
//
// Usage INSIDE a view (children of Flickables land in contentItem, so the
// explicit parent is required):
//   ListView { id: list
//       WheelScroll { parent: list; target: list }
//   }
MouseArea {
    property Flickable target: null
    // Optional: called with the wheel's angleDelta.y when the target is
    // already at the end the notch is pushing towards, so a page can carry on
    // where its list stops. Content that does not overflow is at both ends.
    property var chain: null

    parent: target
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    z: 50

    onWheel: (w) => {
        if (!target) { w.accepted = false; return }
        const rows = Number(Settings.uiGet("scrollSpeed", 3))
        const step = (w.angleDelta.y / 120) * rows * 52
        const minY = target.originY
        const maxY = Math.max(minY, target.originY + target.contentHeight - target.height)
        if (chain) {
            const stuck = step > 0 ? target.contentY <= minY + 0.5
                                   : target.contentY >= maxY - 0.5
            if (stuck) { chain(w.angleDelta.y); w.accepted = true; return }
        }
        target.cancelFlick()
        target.contentY = Math.max(minY, Math.min(maxY, target.contentY - step))
        w.accepted = true
    }
}
