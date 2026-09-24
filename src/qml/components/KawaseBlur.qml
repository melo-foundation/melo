import QtQuick
import ".."

// Large-radius background blur. MultiEffect's blur is a fixed pyramid whose reach
// saturates (Qt documents the useful range up to 64), and blurring a downscaled
// texture pops at each integer downscale step. Dual Kawase halves the image per
// pass with five bilinear taps (eight on the way up), so the chain costs at most
// 4/3 of the first pass and `offset` is continuous within a depth.
Item {
    id: root

    property Item sourceItem: null
    property real radius: 0          // px, in the source's own coordinates
    readonly property bool active: radius > 0.5 && sourceItem !== null

    // Depth is limited by what the blur can hide: each level halves resolution, so a
    // level is allowed only once the blur spans four of its texels (2^d source pixels
    // each); earlier, the result reads as neither sharp nor blurred. BackgroundLayer
    // blurs with MultiEffect up to 64px, so this only sees wider blurs.
    readonly property int depth: {
        if (!active) return 0
        let d = 0
        while (d < 5 && radius >= 4.0 * Math.pow(2, d + 1)) ++d
        return d
    }

    // Chain reach is about offset * (2^(depth+1) - 1), each pass's half-texel step
    // doubling in source pixels. The depth rule keeps offset within ~1.5-5, where
    // Kawase looks right: below ~1 the taps collapse, far above it the ring shows.
    readonly property real offset:
        Math.max(0.6, Math.min(5.5, radius / (Math.pow(2, depth + 1) - 1)))

    // The chain is written out rather than generated: each stage's source is
    // the previous stage's texture, which a Repeater cannot express. Stages
    // deeper than `depth` still render but nothing reads them.

    // --- level 0: the source at full size -------------------------------
    ShaderEffectSource {
        id: l0
        anchors.fill: parent
        // sourceItem null when idle: a ShaderEffectSource renders its source
        // into an FBO whether or not anything draws the result, so leaving the
        // chain wired up would run five passes to display nothing.
        sourceItem: root.active ? root.sourceItem : null
        // The picture draws itself only when there is no chain drawing it.
        hideSource: root.active
        live: true
        visible: false
        recursive: false
    }

    // Down chain. Each ShaderEffect is wrapped in a source of half the size.
    ShaderEffect {
        id: d1e; visible: false
        width: Math.max(1, Math.round(root.width / 2)); height: Math.max(1, Math.round(root.height / 2))
        property var src: l0;  property real offset: root.offset
        property real texW: Math.max(1, root.width);      property real texH: Math.max(1, root.height)
        fragmentShader: "../shaders/kawase_down.frag.qsb"
    }
    ShaderEffectSource { id: d1; visible: false; sourceItem: root.active ? d1e : null; live: true
                         width: d1e.width; height: d1e.height; hideSource: true }

    ShaderEffect {
        id: d2e; visible: false
        width: Math.max(1, Math.round(root.width / 4)); height: Math.max(1, Math.round(root.height / 4))
        property var src: d1;  property real offset: root.offset
        property real texW: Math.max(1, d1.width);        property real texH: Math.max(1, d1.height)
        fragmentShader: "../shaders/kawase_down.frag.qsb"
    }
    ShaderEffectSource { id: d2; visible: false; sourceItem: root.active ? d2e : null; live: true
                         width: d2e.width; height: d2e.height; hideSource: true }

    ShaderEffect {
        id: d3e; visible: false
        width: Math.max(1, Math.round(root.width / 8)); height: Math.max(1, Math.round(root.height / 8))
        property var src: d2;  property real offset: root.offset
        property real texW: Math.max(1, d2.width);        property real texH: Math.max(1, d2.height)
        fragmentShader: "../shaders/kawase_down.frag.qsb"
    }
    ShaderEffectSource { id: d3; visible: false; sourceItem: root.active ? d3e : null; live: true
                         width: d3e.width; height: d3e.height; hideSource: true }

    ShaderEffect {
        id: d4e; visible: false
        width: Math.max(1, Math.round(root.width / 16)); height: Math.max(1, Math.round(root.height / 16))
        property var src: d3;  property real offset: root.offset
        property real texW: Math.max(1, d3.width);        property real texH: Math.max(1, d3.height)
        fragmentShader: "../shaders/kawase_down.frag.qsb"
    }
    ShaderEffectSource { id: d4; visible: false; sourceItem: root.active ? d4e : null; live: true
                         width: d4e.width; height: d4e.height; hideSource: true }

    ShaderEffect {
        id: d5e; visible: false
        width: Math.max(1, Math.round(root.width / 32)); height: Math.max(1, Math.round(root.height / 32))
        property var src: d4;  property real offset: root.offset
        property real texW: Math.max(1, d4.width);        property real texH: Math.max(1, d4.height)
        fragmentShader: "../shaders/kawase_down.frag.qsb"
    }
    ShaderEffectSource { id: d5; visible: false; sourceItem: root.active ? d5e : null; live: true
                         width: d5e.width; height: d5e.height; hideSource: true }

    // The deepest texture this radius asked for. Everything below is unwound.
    readonly property var deepest: root.depth >= 5 ? d5
                                 : root.depth === 4 ? d4
                                 : root.depth === 3 ? d3
                                 : root.depth === 2 ? d2
                                 : root.depth === 1 ? d1 : l0
    readonly property real deepestW: root.depth >= 5 ? d5.width
                                   : root.depth === 4 ? d4.width
                                   : root.depth === 3 ? d3.width
                                   : root.depth === 2 ? d2.width
                                   : root.depth === 1 ? d1.width : Math.max(1, root.width)
    readonly property real deepestH: root.depth >= 5 ? d5.height
                                   : root.depth === 4 ? d4.height
                                   : root.depth === 3 ? d3.height
                                   : root.depth === 2 ? d2.height
                                   : root.depth === 1 ? d1.height : Math.max(1, root.height)

    // Up chain: one pass back for each one down, ending at full size. Written
    // as a single widening pass per level, sources chosen by depth.
    ShaderEffect {
        id: u4e; visible: false
        width: Math.max(1, Math.round(root.width / 16)); height: Math.max(1, Math.round(root.height / 16))
        property var src: root.depth >= 5 ? d5 : root.deepest
        property real offset: root.offset
        property real texW: root.depth >= 5 ? d5.width : root.deepestW
        property real texH: root.depth >= 5 ? d5.height : root.deepestH
        fragmentShader: "../shaders/kawase_up.frag.qsb"
    }
    ShaderEffectSource { id: u4; visible: false; sourceItem: root.active ? u4e : null; live: true
                         width: u4e.width; height: u4e.height; hideSource: true }

    ShaderEffect {
        id: u3e; visible: false
        width: Math.max(1, Math.round(root.width / 8)); height: Math.max(1, Math.round(root.height / 8))
        property var src: root.depth >= 5 ? u4 : (root.depth === 4 ? d4 : root.deepest)
        property real offset: root.offset
        property real texW: root.depth >= 5 ? u4.width : (root.depth === 4 ? d4.width : root.deepestW)
        property real texH: root.depth >= 5 ? u4.height : (root.depth === 4 ? d4.height : root.deepestH)
        fragmentShader: "../shaders/kawase_up.frag.qsb"
    }
    ShaderEffectSource { id: u3; visible: false; sourceItem: root.active ? u3e : null; live: true
                         width: u3e.width; height: u3e.height; hideSource: true }

    ShaderEffect {
        id: u2e; visible: false
        width: Math.max(1, Math.round(root.width / 4)); height: Math.max(1, Math.round(root.height / 4))
        property var src: root.depth >= 4 ? u3 : (root.depth === 3 ? d3 : root.deepest)
        property real offset: root.offset
        property real texW: root.depth >= 4 ? u3.width : (root.depth === 3 ? d3.width : root.deepestW)
        property real texH: root.depth >= 4 ? u3.height : (root.depth === 3 ? d3.height : root.deepestH)
        fragmentShader: "../shaders/kawase_up.frag.qsb"
    }
    ShaderEffectSource { id: u2; visible: false; sourceItem: root.active ? u2e : null; live: true
                         width: u2e.width; height: u2e.height; hideSource: true }

    ShaderEffect {
        id: u1e; visible: false
        width: Math.max(1, Math.round(root.width / 2)); height: Math.max(1, Math.round(root.height / 2))
        property var src: root.depth >= 3 ? u2 : (root.depth === 2 ? d2 : root.deepest)
        property real offset: root.offset
        property real texW: root.depth >= 3 ? u2.width : (root.depth === 2 ? d2.width : root.deepestW)
        property real texH: root.depth >= 3 ? u2.height : (root.depth === 2 ? d2.height : root.deepestH)
        fragmentShader: "../shaders/kawase_up.frag.qsb"
    }
    ShaderEffectSource { id: u1; visible: false; sourceItem: root.active ? u1e : null; live: true
                         width: u1e.width; height: u1e.height; hideSource: true }

    // The visible result, full size.
    ShaderEffect {
        id: out0
        anchors.fill: parent
        visible: root.active
        property var src: root.depth >= 2 ? u1 : (root.depth === 1 ? d1 : l0)
        property real offset: root.offset
        property real texW: root.depth >= 2 ? u1.width : (root.depth === 1 ? d1.width : Math.max(1, root.width))
        property real texH: root.depth >= 2 ? u1.height : (root.depth === 1 ? d1.height : Math.max(1, root.height))
        fragmentShader: "../shaders/kawase_up.frag.qsb"
    }

}
