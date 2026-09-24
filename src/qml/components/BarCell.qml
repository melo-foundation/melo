import QtQuick
import "barcells"
import ".."

// One cell of a bar row: an element the document names, loaded by type. The row
// lays it out; this says how wide it wants to be and whether it is drawn. Each
// kind is a file under barcells/ plus one line below.
Item {
    id: cell
    property var doc: ({})
    // the ink the row asks its words to take, if it asks for one
    property string ink: ""
    property var bar
    property var layout                   // the BarLayout, for its width
    readonly property string type: doc.type || "spacer"
    readonly property bool flex: (doc.flex || 0) > 0
    readonly property real flexWeight: doc.flex || 0
    readonly property bool centre: doc.centre === true
    readonly property real gap: doc.gap !== undefined ? doc.gap : -1   // -1: the row's
    // the space after the cell, added to whatever gap follows it: `gap` is the
    // space before, so without this the last cell in a run cannot hold itself
    // off the end and a cell cannot push the next one away on its own
    readonly property real gapAfter: doc.gapAfter > 0 ? Number(doc.gapAfter) : 0
    // built off the frame; ready when the item exists
    readonly property bool ready: content.status === Loader.Ready
    // drawn at all: wide enough, and laid out by its row at least once
    readonly property bool shown: ready && (doc.minWidth === undefined || (layout ? layout.width : 0) >= doc.minWidth)
                                  && !(type === "button" && !doc.id)
    // positioned by its row at least once: until then it is not drawn, so
    // a new cell never sits at the edge for a frame. A cell outside a row —
    // the arranger's shelf — is placed by whoever holds it.
    property bool placed: true
    // a Loader made synchronous completes its incubation at once
    function finish() { content.asynchronous = false }
    visible: shown && width > 0 && placed
    // the one being dragged, in the arranger's preview: faint, where it would land
    opacity: doc._drag === true ? 0.3 : 1
    // a cell moves as the queue's rows do when another is dragged past it —
    // while a drag is in flight, the preview on the bar, and while the bar
    // morphs one layout into a near-identical one: after either the row
    // lays out plainly, and reads back the widths it set
    property bool rowAnimating: false     // its row is drawing a change to itself
    readonly property bool gliding: rowAnimating
                                    || (bar ? (bar.docOverride !== null && bar.docOverride !== undefined) || bar.morphing === true : false)
    // a cell's first placement is instant — it appears where it belongs and
    // squeezes open there — later ones glide
    Behavior on x { enabled: cell.gliding && cell.placed; NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase } }
    Behavior on width { enabled: cell.gliding; NumberAnimation { duration: Theme.motionMove; easing.type: Theme.motionEase } }
    // on its way out of a morph: it squeezes to nothing, then the row drops it
    readonly property bool leaving: doc._leave === true
    // squeezing in or out, the content is cut at the edge rather than overflowing it
    clip: gliding && width < contentW - 0.5
    // what it wants when not flexed
    readonly property real contentW: content.item ? content.item.implicitWidth : 0
    // At most this wide, flexed or not (`maxW`, px); unset, as wide as it is given
    readonly property real maxW: doc.maxW > 0 ? doc.maxW : Infinity
    readonly property real natural: leaving ? 0 : Math.min(contentW, maxW)
    implicitWidth: natural
    implicitHeight: content.item ? content.item.implicitHeight : 0
    height: implicitHeight
    function fmt(v) {
        if (!isFinite(v) || v <= 0) return "0:00"
        const m = Math.floor(v / 60), sec = Math.floor(v % 60)
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    Component.onCompleted: Theme.cellBuilds++
    Loader {
        id: content
        anchors.fill: parent
        asynchronous: true
        sourceComponent: type === "thumb" ? thumbC : type === "title" ? titleC : type === "artist" ? artistC
                       : type === "prev" || type === "play" || type === "playdisc" || type === "next" ? transportC
                       : type === "scrub" ? scrubC
                       : type === "elapsed" || type === "total" || type === "countdown" || type === "time" ? timesC
                       : type === "button" ? buttonC : type === "volume" ? volumeC : spacerC
    }

    Component { id: thumbC;     ThumbCell     { host: cell } }
    Component { id: titleC;     TitleCell     { host: cell } }
    Component { id: artistC;    ArtistCell    { host: cell } }
    Component { id: transportC; TransportCell { host: cell } }
    Component { id: scrubC;     ScrubCell     { host: cell } }
    Component { id: timesC;     TimesCell     { host: cell } }
    Component { id: buttonC;    ButtonCell    { host: cell } }
    Component { id: volumeC;    VolumeCell    { host: cell } }
    Component { id: spacerC;    SpacerCell    { host: cell } }
}
