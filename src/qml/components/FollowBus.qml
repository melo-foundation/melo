pragma Singleton
import QtQuick

// Holds the single FrameClock.syncing connection for every StyledFill, made once
// at first use. A fill that scrolls calls mark(); flush() runs followContent() on
// the queue each frame and empties it.
// Per-fill connections dispatched 251,409 times in a 20s drag, 85% of them no-ops.
// Gating them on the dirty flag is worse still: Qt then edits ~150 connections a
// frame, each walking the target's connection list.
QtObject {
    id: bus

    property var pending: []
    readonly property bool hooked: typeof FrameClock !== "undefined" && FrameClock !== null

    function mark(fill) {
        if (fill.followDirty) return        // already queued this frame
        fill.followDirty = true
        bus.pending.push(fill)
    }

    // A delegate can be destroyed between marking and the next sync, and a
    // destroyed QObject throws on property access. The queue only ever holds
    // the frame's dirty fills (~60), so the scan is short.
    function forget(fill) {
        if (!fill.followDirty) return
        fill.followDirty = false
        const i = bus.pending.indexOf(fill)
        if (i >= 0) bus.pending.splice(i, 1)
    }

    function flush() {
        const p = bus.pending
        if (p.length === 0) return
        for (let i = 0; i < p.length; ++i) {
            const f = p[i]
            f.followDirty = false
            f.followContent()
        }
        p.length = 0
    }

    Component.onCompleted: if (bus.hooked) FrameClock.syncing.connect(bus.flush)
}
