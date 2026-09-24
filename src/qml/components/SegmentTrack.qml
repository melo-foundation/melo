import QtQuick
import ".."

// The track and the travelling accent pill behind a strip of segment-style
// SelectTabs, which draw only their words. Shown only when the strip's kind is
// segment, so a site places it once.
Item {
    id: seg
    property Item strip          // the Row of SelectTabs
    property string style: "filled"
    property real pad: Theme.tabTrackPad   // the track around the strip
    property real inset: 2       // the pill inside a tab, sideways
    visible: style === "segment" && strip !== null
    x: strip ? strip.x - pad : 0
    y: strip ? strip.y - pad : 0
    width: strip ? strip.width + pad * 2 : 0
    height: strip ? strip.height + pad * 2 : 0
    // the active tab: reading each child's active registers it, so a
    // change of selection moves the pill
    readonly property Item active: {
        if (!strip) return null
        const cs = strip.children
        for (let i = 0; i < cs.length; ++i)
            if (cs[i].visible && cs[i].active === true) return cs[i]
        return null
    }
    Surface {
        anchors.fill: parent
        radius: Theme.pill(height / 2)
        role: "button"
        borderRole: "border"
        borderWidth: 1
    }
    // The pill animates only when the selection changes, never on a relayout
    // (back from the mini player, a resize). It follows `shown`, which only
    // settle() sets, after `travelling` is on; following `active` directly
    // would race the handler. settle() waits a tick because choosing a tab to
    // the right turns the old one off first, so `active` passes through null.
    property Item shown: null
    property bool travelling: false
    onActiveChanged: Qt.callLater(settle)
    function settle() {
        if (active === shown) return
        travelling = shown !== null && active !== null
        if (travelling) travelEnd.restart()
        shown = active
    }
    Component.onCompleted: shown = active
    Timer { id: travelEnd; interval: Theme.motionMove + 50; onTriggered: seg.travelling = false }
    Surface {
        visible: seg.shown !== null
        x: seg.pad + (seg.shown ? seg.shown.x : 0) + seg.inset
        y: seg.pad + (seg.shown ? seg.shown.y : 0)
        width: seg.shown ? seg.shown.width - seg.inset * 2 : 0
        height: seg.shown ? seg.shown.height : 0
        radius: Theme.pill(height / 2)
        role: "accent"
        Behavior on x { enabled: seg.travelling; NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase } }
        Behavior on width { enabled: seg.travelling; NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase } }
    }
}
