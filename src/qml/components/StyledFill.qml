import QtQuick
import QtQuick.Window
import ".."

// A procedural fill (styled.frag) over this item, or through `mask`'s coverage (a
// same-size layered item, like HueLumText's glyphs). The pattern lives in window
// space and mapToItem is not reactive, so the position is recomputed per frame.
// `layers` gives a stack, bottom to top; the scalar kind/params/colourA remain
// the API for one fill.
Item {
    id: root
    property Item mask: null
    property string kind: "rainbow"
    property var params: Theme.styledOf(null)
    // an entry that has no levers yet reads as the defaults, never as undefined
    readonly property var prm: params && typeof params === "object" ? params : Theme.styledOf(null)
    property color colourA: "#ffffff"
    // one line's height in px, for shape-aware edge widths; 0: the whole item
    property real lineHeightPx: 0
    // the pattern in this item's own space rather than the window's: a
    // preview shows the whole of it
    property bool local: false
    // What an adaptive layer reads. Only needed when a stack has one; the
    // scene's own is the right default for everything that does not have a
    // backdrop of its own to name.
    property Item backdrop: Theme.backdrop

    // Theme.layersOf's shape: source, colour, params, opacity, mask, maskDist
    property var layers: null
    // Each layer's alpha is applied per layer here. A caller multiplying the
    // entry's colour alpha into its own opacity would apply the BOTTOM layer's
    // alpha to all of them. The one-layer fallback below hands over an opaque
    // colour, because there the caller still holds the alpha.
    readonly property var stack: (Theme.isList(layers) && layers.length > 0) ? layers
        : [({ source: kind, colour: Qt.rgba(colourA.r, colourA.g, colourA.b, 1),
              params: prm, opacity: 1, mask: "all", maskDist: 0 })]

    // First visible layer (Theme.coveredBelow): layers under an opaque one would be a
    // shader pass each for hidden pixels. A chain keeps them, since its rungs are
    // indexed by the whole stack.
    readonly property int firstDrawn: chained ? 0 : Math.max(Theme.coveredBelow(stack), groundCovers ? 1 : 0)

    // A surface already paints its role's bottom colour with a Rectangle under this
    // fill; the caller names that colour here so a stack starting with it opaque is
    // not drawn again. Transparent skips nothing.
    property color groundColour: "transparent"
    readonly property bool groundCovers: {
        if (stack.length < 2 || groundColour.a < 1 || opacity < 1) return false
        const b = stack[0]
        return Theme.sourceOf(b) === "colour" && String(b.mask || "all") === "all"
            && String(b.blend || "").length === 0
            && (b.opacity !== undefined ? b.opacity : 1) >= 1
            && Qt.colorEqual(Theme.colorOf(b, "#ffffff"), groundColour)
    }

    // Item opacity applies per node, so at half strength each layer would show the
    // one below through it; rendering the stack to a texture applies opacity once.
    // Only with more than one drawn layer, below full opacity, and not chained (a
    // chain already ends in one node).
    layer.enabled: opacity < 1 && stack.length - firstDrawn > 1 && !chained

    // One distance field for the stack, depending only on mask and size, so
    // shape-aware layers and mask modes share it. A shape the shader can solve
    // analytically needs no EdgeField at all.
    readonly property bool analyticShape: rad.x >= 0
    readonly property bool wantsField: {
        if (analyticShape) return false
        for (const L of stack)
            if (Theme.fillShape(Theme.sourceOf(L)) || Theme.maskModes.indexOf(String(L.mask)) > 0) return true
        return false
    }
    readonly property bool anyImage: {
        for (const L of stack) if (Theme.fillImage(Theme.sourceOf(L))) return true
        return false
    }
    // The BOTTOM layer has no layers under it (what is under it is the
    // surface's backdrop), so its mode is the entry's, applied by
    // BlendSurface. Everything above blends here.
    readonly property bool hasBlend: {
        for (let i = 1; i < stack.length; ++i)
            if (String(stack[i].blend || "").length > 0) return true
        return false
    }
    // A mode the hardware cannot do turns the stack into a chain: every layer to a
    // texture, composited rung by rung, since overlay and the rest must read what is
    // under them. That costs a pass per layer and per rung, against none for the six
    // blend factors, so only such a mode chains.
    readonly property bool chained: Theme.stackChains(stack)
    // No rung for the bottom layer: it has nothing below, so the first real rung uses
    // its texture as the backdrop. A rung applies `amount` only to what is above it,
    // so a translucent bottom layer or a bottom filter keeps its rung.
    readonly property bool bottomIsTexture: {
        const b = stack[0]
        if (Theme.isFilter(Theme.sourceOf(b))) return false
        return (b.opacity !== undefined ? b.opacity : 1) * Theme.colorOf(b, "#ffffff").a >= 1
    }
    readonly property bool hasAdaptive: {
        for (const L of stack) if (Theme.sourceOf(L) === "adaptive") return true
        return false
    }

    property vector4d geo0: Qt.vector4d(0, 0, 1, 1)
    // ...and where it sits in the SCROLLED CONTENT, for a layer anchored to
    // that instead. One pattern down a whole list rather than across the
    // viewport it happens to be showing through: the difference is whether a
    // card keeps its own slice while it scrolls or slides across a fixed one.
    property vector4d geoScroll: Qt.vector4d(0, 0, 1, 1)
    function updateOrigin() {
        // Size is valid before the item is attached to a window. Left at 1x1
        // until the slow tick, geo0 makes shape normals vanish on the first
        // still frame, then pop in a third of a second later.
        const p = root.Window.window ? root.mapToItem(null, 0, 0) : Qt.point(0, 0)
        const ww = Math.max(1, width), hh = Math.max(1, height)
        // geo0 is a uniform, and writing it marks the effect dirty and renders a frame;
        // the slow tick re-maps every visible fill, so unconditional writes would repaint
        // an idle app three times a second.
        // the content mapping is only paid for where a layer asks for it
        if (wantsScroll && scroller) {
            const c = mapToItem(scroller.contentItem, 0, 0)
            if (geoScroll.x !== c.x || geoScroll.y !== c.y || geoScroll.z !== ww || geoScroll.w !== hh)
                geoScroll = Qt.vector4d(c.x, c.y, ww, hh)
        }
        // where it was when it was still, for followContent()
        restOx = p.x; restOy = p.y
        if (scroller) { restCx = scroller.contentX; restCy = scroller.contentY }
        if (geo0.x === p.x && geo0.y === p.y && geo0.z === ww && geo0.w === hh) return
        geo0 = Qt.vector4d(p.x, p.y, ww, hh)
    }
    // Not re-mapped while scrolling: an item in a Flickable moves by exactly the
    // content's travel, so the map is taken at rest (slow tick, size change) and the
    // live origin is that minus the travel since. geoScroll, the position in the
    // content, does not change with scrolling.
    property real restOx: 0
    property real restOy: 0
    property real restCx: 0
    property real restCy: 0
    function followContent() {
        if (!scroller) return
        geo0 = Qt.vector4d(restOx - (scroller.contentX - restCx),
                           restOy - (scroller.contentY - restCy),
                           Math.max(1, width), Math.max(1, height))
    }
    readonly property bool wantsScroll: {
        for (const L of stack) if (String(L.space) === "scroll") return true
        return false
    }
    // Synchronous, because the shader reads geo0 this frame: deferred, a
    // window-anchored pattern paints at the previous step's offset and the surface
    // warps during a drag.
    onWidthChanged: updateOrigin()
    onHeightChanged: updateOrigin()
    // a stack that has just asked for the content mapping has never had one:
    // scrolling no longer re-maps, so nothing else would fill it in
    onWantsScrollChanged: updateOrigin()
    Component.onCompleted: { scroller = findScroller(); updateOrigin(); Qt.callLater(rebindField) }
    Window.onWindowChanged: { scroller = findScroller(); updateOrigin(); Qt.callLater(rebindField) }
    // REQUIRED, not housekeeping: a queued fill that is destroyed without
    // forget() leaves a dead QObject in FollowBus.pending, and the next flush
    // throws on it. Delegates are destroyed mid-scroll, so this fires.
    Component.onDestruction: { if (heldField.length > 0 && fieldCache) fieldCache.release(heldField)
                               if (root.frameHook) FollowBus.forget(root) }
    // Refreshed on Theme's slow tick, not per frame: per-frame mapToItem for several
    // hundred fills is most of a core while idle. A moving label carries its pattern
    // briefly, then re-aligns.
    Connections {
        target: Theme
        enabled: root.visible && !root.local
        function onSlowTickChanged() { root.updateOrigin() }
    }
    // Except while scrolling, where the slow tick would let the pattern ride along
    // for up to 300ms and then snap back, every card at once. An item in a Flickable
    // moves exactly when its content does, so that is what is followed; only a moving
    // scroller costs anything. The walk up is once per fill.
    property Item scroller: null
    function findScroller() {
        let p = parent
        while (p) {
            if (p.flickableDirection !== undefined && p.contentY !== undefined) return p
            p = p.parent
        }
        return null
    }
    // geo0 is written once a frame, not per event: a drag delivers ~3 pointer moves
    // per frame, and per-event writes were mostly overwritten before drawing. Events
    // mark the fill dirty; FrameClock.syncing (beforeSynchronizing, not frameSwapped,
    // which paints one frame stale) flushes it. -17% cycles on a drag.
    // Without FrameClock (qmltestrunner) the fill would never flush, so it writes per
    // event instead (tst_scrollfills). Known limit: a hook that exists but stays
    // silent for one window is not covered.
    // Only the scroller Connections below is gated on `visible`: a fill hidden after
    // it is queued is still flushed, so its offset cannot go stale while hidden.
    readonly property bool frameHook: typeof FrameClock !== "undefined" && FrameClock !== null
    property bool followDirty: false
    function markFollow() {
        if (!frameHook) { followContent(); return }
        // FollowBus holds the one FrameClock connection for every fill and
        // calls followContent() on whatever is queued when the frame syncs.
        FollowBus.mark(root)
    }
    Connections {
        target: root.visible && !root.local ? root.scroller : null
        function onContentXChanged() { root.markFollow() }
        function onContentYChanged() { root.markFollow() }
    }
    // what a layer binds when there is nothing to bind: every declared
    // sampler needs a texture, and the field only exists for some stacks
    readonly property Item blank: blankTex
    readonly property Item field: sharedField ? sharedField : edgeField.item
    // how far in the field is measured: 32, or as far as a layer's contour
    // reaches — a stack pays for the deeper scan only when it asks
    readonly property real fieldReach: Theme.fieldReach(stack)

    // Names a mask other fills share (BlendSurface passes its rounded rectangle), so
    // the distance field is built once per shape per window. Empty: the fill keeps its
    // own. Glyph coverage is never shared.
    property string maskKey: ""
    // ...and the shape behind that mask, when the caller knows it is a
    // rounded rectangle. See FillLayer.rad.
    property vector4d rad: Qt.vector4d(-1, -1, -1, -1)
    // A surface body takes the half-resolution field, a glyph does not: see
    // EdgeField.coarse. Set by the callers that know their mask is a filled
    // shape rather than lettering.
    property bool coarseField: false
    // A drawn pen is not a soft bevel. Half-resolution geometry moves a
    // one-pixel toon outline off the real edge and breaks it around corners.
    // Keep the optimization for soft materials, including other stacks that
    // share this mask; the resolution is part of the cache key.
    readonly property bool fieldCoarse: {
        if (!coarseField) return false
        for (const L of stack) if (Theme.sourceOf(L) === "toon") return false
        return true
    }
    readonly property string fieldKey: maskKey.length > 0 && wantsField && mask !== null
        ? "f:" + maskKey + ":" + fieldReach + (fieldCoarse ? ":c" : "") : ""
    property Item sharedField: null
    property Item fieldCache: null
    property string heldField: ""
    // The new one before the old one is let go, for the reason BlendSurface's
    // own rebind does it in that order.
    function rebindField() {
        const c = Theme.fillCache(Window.window)
        if (c !== fieldCache) {
            if (heldField.length > 0 && fieldCache) fieldCache.release(heldField)
            heldField = ""
            fieldCache = c
        }
        if (!fieldCache) { sharedField = null; return }
        if (heldField === fieldKey) return
        const old = heldField
        heldField = fieldKey
        // At the mask's size, not this item's. The shared mask holds the size
        // its shape settled at, and every reader samples the field in uv — so
        // the field has to cover the mask, exactly, or the distances are read
        // against a picture of another shape.
        sharedField = fieldKey.length > 0
            ? fieldCache.field(fieldKey, mask, mask.width, mask.height, fieldReach, fieldCoarse)
            : null
        if (old.length > 0) fieldCache.release(old)
    }
    // ...on the key that stuck, for the reason BlendSurface's rebind is
    // deferred: the mask's own key walks there through the corner radii.
    onFieldKeyChanged: Qt.callLater(rebindField)
    // a texture to bind when there is no mask: every declared sampler binds
    Item { width: 0; height: 0; clip: true
           // One texture for the app: an Image is a texture provider on its
           // own, and the scene graph keeps one copy per source per window, so
           // every fill in melo naming Theme.blankTex shares a single white
           // pixel.
           Image { id: blankTex; source: Theme.blankTex }
           Loader {
               id: edgeField
               objectName: "edgeFieldCache"
               width: root.width; height: root.height
               // Only with a size: a sizeless layer is an empty render target the scene graph
               // still grabs during preprocess, inside the running pass. Not when `fieldKey`
               // names a shape the window's cache already holds.
               active: root.wantsField && root.mask !== null
                       && root.width > 0 && root.height > 0
                       && root.fieldKey.length === 0
               sourceComponent: EdgeField { mask: root.mask; reach: root.fieldReach
                                            coarse: root.fieldCoarse }
           }
           // The picture for an image layer, at most 1024 wide; none without one. Bound
           // straight to the sampler, the Image's texture is the scene graph's one copy per
           // source per window; a layer would be a private copy per fill. Tiling is fract()
           // in the shader.
           Repeater {
               id: pictures
               model: root.anyImage ? root.stack.length : 0
               Image {
                   required property int index
                   readonly property var modelData: root.stack[index]
                   readonly property string wanted: Theme.fillImage(Theme.sourceOf(modelData))
                           ? ((modelData.params && modelData.params.src) || "") : ""
                   // Native placement and nine-slice cuts are in SOURCE pixels;
                   // decoding those at 1024 would silently rescale their borders.
                   readonly property bool nativeFit: Theme.imageOption(Theme.styledOf(modelData), "fit") >= 4
                   // A vector picture with no requested size must load synchronously: Qt before
                   // 6.12 rasterises it at 1x on the async path but still divides by the screen
                   // ratio, reporting half size at 2x (QTBUG-143453). The cache key ignores ratio
                   // and async flag, so one async load poisons later sync loads; the properties are
                   // set here in order, source last, because bindings could start an async load
                   // first.
                   function request() {
                       const vector = nativeFit && /\.(svgz?|pdf)(\?|#|$)/i.test(wanted)
                       source = ""
                       asynchronous = !vector
                       sourceSize = Qt.size(nativeFit ? 0 : 1024, 0)
                       source = wanted
                   }
                   onWantedChanged: request()
                   onNativeFitChanged: request()
                   Component.onCompleted: request()
                   // A vector picture is rasterised at whole device pixels, so
                   // 24px at 1.9x is 46px and reads back as 24.21. FillLayer
                   // takes the size from here.
                   width: Math.round(implicitWidth); height: Math.round(implicitHeight)
               }
           } }

    // The model is the count, not the list: replacing a JS-array model rebuilds every
    // delegate, and `stack` is rebuilt on every colour or params change (each hover
    // where inks are fills). All else reaches the shader as uniforms.
    Repeater {
        id: fills
        model: root.chained ? 0 : root.stack.length
        FillLayer {
            required property int index
            objectName: "fillLayer_" + index
            anchors.fill: parent
            host: root
            modelData: root.stack[index]
            // the Image for THIS layer, once the Repeater has built it; count
            // notifies, so the binding re-runs when the pictures appear
            picture: lImage && pictures.count > index ? pictures.itemAt(index) : null
            // Bottom to top across every Repeater. An adaptive layer is drawn
            // by a HueLum below and a blended one by a BlendRect; z is what
            // keeps them interleaved in the stack's own order.
            z: index
            // drawn by the loader below instead, through a hardware mode —
            // and a filter here has nothing under it to read, so nothing
            visible: index >= root.firstDrawn
                     && lKind !== "adaptive" && !blended && !Theme.isFilter(lKind)
            readonly property bool blended: index > 0 && String(modelData.blend || "").length > 0
            opacity: (modelData.opacity !== undefined ? modelData.opacity : 1) * lCol.a
        }
    }
    // The two side paths, built only where taken: an empty Repeater is still an
    // object per fill, and the plain path (most entries) needs neither.
    Loader {
        anchors.fill: parent
        active: (root.hasBlend && !root.chained) || root.hasAdaptive
        sourceComponent: Item {
            anchors.fill: parent
            // Blended layers: each meets the layers under it through a BlendRect hardware
            // mode; the bottom layer's mode is the entry's, applied by BlendSurface. Each is a
            // second copy rendered in the zero-sized clip, since a hidden source hands over an
            // empty texture (see BlendItem).
            Repeater {
                model: root.hasBlend && !root.chained ? root.stack.length : 0
                Loader {
                    id: bLoad
                    required property int index
                    readonly property var modelData: root.stack[index]
                    anchors.fill: parent
                    z: index
                    active: index > 0 && index >= root.firstDrawn
                            && String(modelData.blend || "").length > 0
                    source: "BlendLayer.qml"
                    // By ID, not `parent`: a Binding is not an Item and has no
                    // parent to resolve names through.
                    Binding {
                        target: bLoad.item; property: "host"; value: root; when: bLoad.item !== null
                    }
                    Binding {
                        target: bLoad.item; property: "entry"; value: bLoad.modelData; when: bLoad.item !== null
                    }
                    Binding {
                        target: bLoad.item; property: "picture"; when: bLoad.item !== null
                        value: pictures.count > bLoad.index ? pictures.itemAt(bLoad.index) : null
                    }
                    Binding {
                        target: bLoad.item; property: "mode"; when: bLoad.item !== null
                        value: String(bLoad.modelData.blend || "normal")
                    }
                }
            }
            // The adaptive layers, which read the backdrop instead of
            // generating a pattern. Nothing is built for a stack that has none,
            // which is every entry that is not one — and every caller that
            // hands over no `layers`.
            Repeater {
                model: root.hasAdaptive ? root.stack.length : 0
                HueLum {
                    required property int index
                    readonly property var modelData: root.stack[index]
                    anchors.fill: parent
                    z: index
                    visible: index >= root.firstDrawn && Theme.sourceOf(modelData) === "adaptive"
                    backdrop: visible ? root.backdrop : null
                    mask: root.mask
                    readonly property vector4d amt: Theme.adaptiveOf(modelData)
                    hue: amt.x; lum: amt.y; sat: amt.z
                    opacity: amt.w * (modelData.opacity !== undefined ? modelData.opacity : 1)
                             * Theme.colorOf(modelData, "#ffffff").a
                }
            }
        }
    }
    // The chain: each layer rendered to a texture and composited onto the one below;
    // only the last rung draws on screen. Rungs live in the zero-sized clip, since an
    // undrawn source hands over an empty texture. Not built without a chain (four
    // objects per fill that most entries never use).
    Loader {
        anchors.fill: parent
        active: root.chained
        sourceComponent: Item {
            anchors.fill: parent
            Item {
                width: 0; height: 0; clip: true
                Repeater {
                    id: chainFills
                    model: root.stack.length
                    FillLayer {
                        required property int index
                        width: root.width; height: root.height
                        host: root
                        modelData: root.stack[index]
                        picture: lImage && pictures.count > index ? pictures.itemAt(index) : null
                        // a filter has nothing of its own to render: no texture
                        readonly property bool isFilter: Theme.isFilter(lKind)
                        visible: !isFilter
                        layer.enabled: !isFilter
                    }
                }
                Repeater {
                    id: chainSteps
                    model: root.stack.length
                    BlendStep {
                        required property int index
                        readonly property var lay: root.stack[index]
                        readonly property string lKind: Theme.sourceOf(lay)
                        width: root.width; height: root.height
                        blank: blankTex
                        // the rung under this one — or, for the first rung above
                        // the bottom layer, that layer's own texture in place of
                        // a rung
                        below: index === 0 ? null
                             : index === 1 && root.bottomIsTexture
                               ? (chainFills.count > 0 ? chainFills.itemAt(0) : null)
                               : (chainSteps.count > index ? chainSteps.itemAt(index - 1) : null)
                        above: chainFills.count > index ? chainFills.itemAt(index) : null
                        // ...and then rung 0 is nothing at all: no target, no draw
                        readonly property bool spare: index === 0 && root.bottomIsTexture
                        visible: !spare
                        mode: Theme.blendIndex(lay.blend)
                        amount: (lay.opacity !== undefined ? lay.opacity : 1) * Theme.colorOf(lay, "#ffffff").a
                        // ...or a filter of what is under it, within its mask
                        filter: Theme.filterIndex(lKind)
                        maskItem: root.mask
                        field: root.field
                        msk: Qt.vector4d(Math.max(0, Theme.maskModes.indexOf(String(lay.mask))),
                                         lay.maskDist !== undefined ? lay.maskDist : 3,
                                         lay.phase !== undefined ? lay.phase : 0, root.fieldReach)
                        par2: Theme.optionVec(lKind, Theme.styledOf(lay), 0)
                        par3: Theme.optionVec(lKind, Theme.styledOf(lay), 4)
                        layer.enabled: !spare
                    }
                }
            }
            // ...and the last rung, put on screen. A composite with nothing
            // under it is a plain draw, so this is the same shader rather than
            // another one.
            BlendStep {
                anchors.fill: parent
                visible: chainSteps.count === root.stack.length
                blank: blankTex
                below: null
                above: chainSteps.count > 0 ? chainSteps.itemAt(chainSteps.count - 1) : null
                mode: 0
            }
        }
    }
}
