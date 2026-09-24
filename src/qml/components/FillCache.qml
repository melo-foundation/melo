import QtQuick

// One coverage mask and one edge field per shape, per window, shared by every
// surface of that shape; unshared, each card in a grid builds three identical
// render targets. Only callers whose mask is a plain rounded rectangle of a known
// size ask; glyph coverage is not shared.
// Under a window, not in Theme: a layer renders only in a scene graph and a
// provider's texture belongs to its window, so Theme keeps a register and the
// cache is a zero-sized, clipped item under that window's contentItem.
Item {
    id: cache
    objectName: "fillCache"
    width: 0; height: 0; clip: true

    // key -> { item, refs, idle }. A plain object: the keys are strings and
    // nothing iterates it per frame.
    property var entries: ({})

    Component {
        id: maskComp
        Rectangle { color: "#ffffff"; layer.enabled: true }
    }
    Component {
        id: fieldComp
        EdgeField {}
    }

    // `props` is the shape: width, height, radius and the four corners.
    function mask(key, props) { return take(key, maskComp, props) }
    // ...and the field over one, which is why it takes the mask item itself
    // rather than a key: the field is only ever built from a mask this cache
    // is already holding.
    function field(key, maskItem, w, h, reach, coarse) {
        return take(key, fieldComp, ({ mask: maskItem, width: w, height: h, reach: reach,
                                       coarse: coarse === true }))
    }

    function take(key, comp, props) {
        let e = entries[key]
        if (!e) {
            sweep()
            const it = comp.createObject(cache, props)
            if (!it) return null
            e = entries[key] = ({ item: it, refs: 0, idle: 0 })
        }
        e.refs += 1
        return e.item
    }
    function release(key) {
        const e = entries[key]
        if (!e || e.refs <= 0) return
        e.refs -= 1
        if (e.refs === 0) e.idle = Date.now()
    }

    // A grace before it goes. A scrolled list destroys the delegate that
    // leaves the viewport and builds one the same shape at the other end in
    // the same frame; evicting on the release would rebuild the mask and the
    // field for every row that passes.
    readonly property int grace: 2000
    // Swept when a shape is taken, not on a timer that would wake the render thread
    // over a still window. Known limit: an unrequested shape is held until the next
    // new one, bounded by the window's distinct surface sizes; add a clock if a theme
    // ever generates shapes without end.
    function sweep() {
        const now = Date.now()
        for (const k in entries) {
            const e = entries[k]
            if (e.refs === 0 && now - e.idle >= grace) { e.item.destroy(); delete entries[k] }
        }
    }
}
