import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import ".."
import "../.."

// Poster: artwork fills the page, title across the bottom. Drag, scroll and
// the page picker all drive one `phase`, which morphs the poster into the sleeve
// with the record sliding out and the reading column beside it.
Item {
    id: s
    property var np
    clip: true

    // A ShaderEffect draws nothing without a GL context, and melo has a path
    // with none. There, the drawn conic sheen and the drawn surface marks
    // stand in for it — the disc keeps a highlight either way.
    readonly property bool shaderOk: (typeof MELO_HAS_GL !== "undefined") && MELO_HAS_GL

    // Same test the player bar uses: a skeleton means "there is no track
    // yet", and the shimmer means "one is on its way". A load mid-song sets
    // loading without clearing the track, and must NOT flash the page back
    // into placeholders.
    readonly property bool loading: !PlayerState.hasTrack

    property real phase: 0        // 0 = poster, 1 = record, 2 = classic
    property bool live: false     // a hand owns it — no easing on top
    Behavior on phase {
        enabled: !s.live
        NumberAnimation { duration: 640; easing.type: Easing.InOutCubic }
    }

    // Optional motion blur on the TYPE only — the artwork is one picture
    // moving and reads fine sharp; it is the copies trading places that the
    // blur is there to cover. Peaks furthest from a stop, which is where the
    // trade happens.
    readonly property real away: 1 - Math.abs(2 * (phase - Math.floor(phase)) - 1)
    readonly property bool blurring: away > 0.02
    function settle() { live = false; phase = Math.round(phase) }
    // The words belong to the stop you are standing on. The classic page's cover
    // moves to make room for them, and the travelling artwork is bound to
    // where that cover is — so leaving with them open warps the whole path.
    // They close as soon as the page is meaningfully between stops.
    onAwayChanged: if (away > 0.06 && np && np.showWords) np.showWords = false
    // one stop per notch, from anywhere that has run out of scroll
    function stepBy(dy) {
        if (Math.abs(phase - Math.round(phase)) > 0.02) return
        const at = Math.round(phase)
        phase = dy < 0 ? Math.min(2, at + 1) : Math.max(0, at - 1)
    }
    // Stage 1 is the poster becoming the record; stage 2 is the record giving
    // way to the classic page. Splitting the phase in
    // two keeps every lerp below inside its own 0..1.
    readonly property real p: Math.min(1, phase)
    readonly property real q: Math.max(0, Math.min(1, phase - 1))
    function lerp(a, b) { return a + (b - a) * s.p }
    // things that only belong to the second half arrive late
    readonly property real late: Math.max(0, (p - 0.5) / 0.5)
    // The picture and the words travel; only what has no counterpart on the
    // classic page — the facts, the record itself — steps aside.
    readonly property real leaving: Math.max(0, 1 - q * 2.2)

    // where the sleeve ends up
    readonly property real sleeveW: Math.min(width * 0.32, height * 0.44, 300)
    readonly property real rigW: sleeveW * 1.6
    // Below this there is no room for a column beside the record, so narrow
    // stacks: record up top, everything it has to say underneath. Same number the bar rearranges
    // on, so the whole window changes shape in one move.
    readonly property bool stacked: width < GridUi.narrowW
    readonly property real pageX: GridUi.padLeft + 34    // the page's inset, in a poster's wider band
    readonly property real sleeveX: stacked ? (width - rigW) / 2 : pageX
    // the album sits on the middle of the page, with room kept below it for
    // the title block it carries
    readonly property real sleeveY: stacked
        ? GridUi.padTop + 18
        : Math.max(GridUi.padTop + 14,
                   Math.min((height - sleeveW) / 2, height - sleeveW - 150))

    // ---- the record, out from behind the sleeve -------------------------
    // Starts inside the sleeve, hidden by the cover, and slides right; nothing fades.
    // Circular shadows so it reads as a disc.
    Repeater {
        model: disc.visible ? 3 : 0
        Rectangle {
            required property int index
            readonly property real k: index + 1
            x: disc.x - k * 1.5
            y: disc.y + k * 3.5
            width: disc.width + k * 3
            height: disc.height + k * 3
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.20 - index * 0.055)
        }
    }

    Item {
        id: disc
        width: s.sleeveW * 0.94
        height: width
        // rides with the cover, so on the way out it goes back in behind it
        // rather than being left standing where the sleeve used to be and
        // fading in open air
        readonly property real baseX: s.sleeveX + (classicPane.coverX - s.sleeveX) * s.q
        readonly property real baseY: s.sleeveY + (classicPane.coverY - s.sleeveY) * s.q
        readonly property real tucked: baseX + (s.sleeveW - width) / 2
        readonly property real out: baseX + s.sleeveW * 0.62
        // out over the first leg, and back in over the start of the second
        readonly property real emerge: s.late * Math.max(0, 1 - s.q / 0.3)
        x: tucked + (out - tucked) * emerge
        y: baseY + (s.sleeveW - height) / 2
        // no fade at all: once it is tucked there is nothing showing anyway
        visible: s.p > 0.3 && emerge > 0.001

        // The angle lives in a property so grooves, label and shader share it and it
        // can be read back (a RotationAnimator's value stays on the render thread until
        // it stops). Paused, not stopped: restarting replays from `from`, snapping to 0.
        property real spinDeg: 0
        NumberAnimation on spinDeg {
            running: true
            paused: !PlayerState.isPlaying || !disc.visible
            loops: Animation.Infinite
            from: 0; to: 360; duration: 6000
        }

        // Everything that turns lives in here. Qt clips to a rectangle, so a masked
        // image would need a layer, which the software path lacks; grooves and a label
        // need neither.
        Rectangle {
            id: discBody
            anchors.fill: parent
            radius: width / 2
            color: "#09090b"
            rotation: disc.spinDeg
            // 46 rings reads as a surface where a few read as rings. Every twelfth is
            // brighter, the track gap. They stop at 0.49 to leave room for the run-out.
            Repeater {
                model: 46
                Rectangle {
                    required property int index
                    readonly property real t: index / 45
                    anchors.centerIn: parent
                    width: parent.width * (0.96 - t * 0.52)
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: (index % 12 === 4) ? Qt.rgba(1, 1, 1, 0.10)
                                                     : Qt.rgba(1, 1, 1, 0.032)
                }
            }

            // ---- the groove, as a record has it ---------------------------
            // A spiral, because concentric rings look static when turned. Built once at
            // unit radius and scaled; built against disc.width it was rebuilt every step of
            // a window drag, 1.5ms each on the pointer thread.
            Shape {
                id: groove
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property real r: disc.width / 2
                visible: r >= 8
                transform: Scale { xScale: groove.r; yScale: groove.r }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.042)
                    strokeWidth: 1 / Math.max(1, groove.r)
                    fillColor: "transparent"
                    PathPolyline {
                        path: {
                            const r0 = 0.44, r1 = 0.955
                            const turns = 46
                            const steps = turns * 36
                            const pts = []
                            for (let i = 0; i <= steps; i++) {
                                const f = i / steps
                                const th = f * turns * 2 * Math.PI
                                const rr = r1 - (r1 - r0) * f
                                pts.push(Qt.point(1 + rr * Math.cos(th),
                                                  1 + rr * Math.sin(th)))
                            }
                            return pts
                        }
                    }
                }
            }

            // ---- the anisotropic version ---------------------------------
            // The shader turns its own groove field from the angle: the modulation is in the
            // disc's frame while the lamp stays in the room's.
            ShaderEffect {
                visible: s.shaderOk
                anchors.fill: parent
                rotation: -disc.spinDeg          // undo the body's turn
                fragmentShader: Qt.resolvedUrl("vinyl.frag.qsb")
                blending: true
                property real spin: disc.spinDeg * Math.PI / 180
                property real lightAngle: -140 * Math.PI / 180
                property real pitch: 34.0
                property real gain: 0.22
                property real specExp: 13
                property real grooveAmt: 0.25
                property real fresnel: 0.70
                property real dust: 0.02
                property real env: 0.48
            }

            // ---- what makes it shimmer -----------------------------------
            // Uneven gloss that turns with the record under a fixed highlight. Kept local
            // (short faint arcs at unrelated radii and angles): a turning full-face gradient
            // reads as a lamp swinging round the disc.
            Shape {
                visible: !s.shaderOk
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                // Static slots, not a Repeater: ShapePath is not an Item, and
                // a Repeater refuses to instantiate it ("Delegate must be of
                // Item type", a warning, then nothing drawn). Icon.qml does
                // the same. start, sweep, radius (of disc width), width, alpha.
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.055)
                    strokeWidth: 3.0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.455
                        radiusY: disc.width * 0.455
                        startAngle: 14
                        sweepAngle: 46
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.04)
                    strokeWidth: 2.0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.437
                        radiusY: disc.width * 0.437
                        startAngle: 128
                        sweepAngle: 31
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.032)
                    strokeWidth: 4.0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.412
                        radiusY: disc.width * 0.412
                        startAngle: 209
                        sweepAngle: 58
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.048)
                    strokeWidth: 2.5
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.396
                        radiusY: disc.width * 0.396
                        startAngle: 297
                        sweepAngle: 24
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.028)
                    strokeWidth: 3.5
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.371
                        radiusY: disc.width * 0.371
                        startAngle: 71
                        sweepAngle: 37
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.036)
                    strokeWidth: 2.0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.344
                        radiusY: disc.width * 0.344
                        startAngle: 243
                        sweepAngle: 43
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.03)
                    strokeWidth: 3.0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.318
                        radiusY: disc.width * 0.318
                        startAngle: 162
                        sweepAngle: 27
                    }
                }
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.026)
                    strokeWidth: 2.5
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: disc.width / 2
                        centerY: disc.height / 2
                        radiusX: disc.width * 0.291
                        radiusY: disc.width * 0.291
                        startAngle: 334
                        sweepAngle: 52
                    }
                }
            }

            // ---- the label: the cover, turning with the record -----------
            // Qt clips to a rectangle, so the picture is square and the run-out ring is drawn
            // over its corners; a mask would need a layer, absent on the software path.
            // 0.30 of the disc across puts the corners at 0.212, inside the ring
            // (0.150-0.218), clear of the grooves.
            Rectangle {   // what the label is when there is no picture yet
                anchors.centerIn: parent
                width: parent.width * 0.30; height: width
                radius: width / 2
                color: "#1a1a20"
            }
            Image {
                id: labelArt
                anchors.centerIn: parent
                width: parent.width * 0.30; height: width
                source: s.np.art
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                // Ready is the whole test: no art, never Ready, fallback stays
                visible: status === Image.Ready
                opacity: 0.88          // it is a printed label, not a screen
            }

            Shape {   // the run-out band, doing the masking on its way past
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: "#0c0c0f"
                    strokeWidth: disc.width * 0.068
                    fillColor: "transparent"
                    PathAngleArc {
                        centerX: disc.width / 2; centerY: disc.height / 2
                        radiusX: disc.width * 0.184; radiusY: disc.width * 0.184
                        startAngle: 0; sweepAngle: 360
                    }
                }
            }
            Rectangle {   // the label's own edge, just outside the picture
                anchors.centerIn: parent
                width: parent.width * 0.306; height: width
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.14)
            }
            Rectangle {   // and the accent, a hairline further out
                anchors.centerIn: parent
                width: parent.width * 0.340; height: width
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g,
                                      Theme.accent.b, 0.45)
            }
            Rectangle {   // spindle
                anchors.centerIn: parent
                width: parent.width * 0.034; height: width
                radius: width / 2
                color: "#000000"
            }
        }
        // Fixed light over the turning grooves. Conical, not linear: circular grooves
        // reflect along their radius, giving two opposed lobes rather than a band.
        Shape {
            // off under the shader, which computes its own specular — two of
            // them is two lamps
            visible: !s.shaderOk
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                fillColor: "transparent"
                // even-odd over two circles: a ring, so the sheen stops at
                // the label. Paper does not shine.
                fillRule: ShapePath.OddEvenFill
                fillGradient: ConicalGradient {
                    centerX: disc.width / 2
                    centerY: disc.height / 2
                    angle: -140                    // where the lamp is
                    GradientStop { position: 0.00; color: "#1affffff" }
                    GradientStop { position: 0.11; color: "#00ffffff" }
                    GradientStop { position: 0.39; color: "#00ffffff" }
                    GradientStop { position: 0.50; color: "#12ffffff" }
                    GradientStop { position: 0.61; color: "#00ffffff" }
                    GradientStop { position: 0.89; color: "#00ffffff" }
                    GradientStop { position: 1.00; color: "#1affffff" }
                }
                PathAngleArc {
                    centerX: disc.width / 2; centerY: disc.height / 2
                    radiusX: disc.width / 2 - 1; radiusY: disc.width / 2 - 1
                    startAngle: 0; sweepAngle: 360
                }
                PathMove { x: disc.width / 2 + disc.width * 0.168; y: disc.height / 2 }
                PathAngleArc {
                    centerX: disc.width / 2; centerY: disc.height / 2
                    radiusX: disc.width * 0.168; radiusY: disc.width * 0.168
                    startAngle: 0; sweepAngle: 360
                }
            }
        }
        Rectangle {   // the outer lip
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.15)
        }
        // The left of the disc is still inside the sleeve, or has just left
        // it. Nothing there is in the light the rest of it is in.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.00; color: "#73000000" }
                GradientStop { position: 0.22; color: "#26000000" }
                GradientStop { position: 0.48; color: "#00000000" }
                GradientStop { position: 1.00; color: "#00000000" }
            }
        }
    }

    // ---- what the picture sits on ----------------------------------------
    // Only at the sleeve stop. Stacked plates rather than a blur: a blur is a layer
    // effect, absent on the software path.
    Repeater {
        model: 4
        Rectangle {
            required property int index
            readonly property real k: index + 1
            readonly property real spread: 1.8
            x: artBox.x - k * spread
            y: artBox.y + k * 4
            width: artBox.width + k * spread * 2
            height: artBox.height + k * spread
            radius: artBox.radius + 3
            opacity: s.p
            color: Qt.rgba(0, 0, 0, 0.20 - index * 0.045)
        }
    }

    // ---- the picture, from full bleed to cover ---------------------------
    // One picture the whole way: full bleed, then the sleeve, then the cover
    // of the classic page, which is the same size as the sleeve, so it travels
    // there rather than dissolving into a second copy of itself.
    Rectangle {
        id: artBox
        x: s.lerp(0, s.sleeveX) + (classicPane.coverX - s.sleeveX) * s.q
        y: s.lerp(0, s.sleeveY) + (classicPane.coverY - s.sleeveY) * s.q
        width: s.lerp(s.width, s.sleeveW) + (classicPane.coverW - s.sleeveW) * s.q
        height: s.lerp(s.height, s.sleeveW) + (classicPane.coverW - s.sleeveW) * s.q
        // No Behavior here. The picture's geometry is already a function of
        // `phase`, which eases; easing it again would make it trail the
        // title, which is a function of the same phase and nothing else.
        // The words toggle eases at its source instead (see Classic).
        radius: Theme.radiusLg * s.q
        color: Theme.card
        clip: true
        // Under the picture, not instead of it: the art arrives a beat after
        // the track does, and a flat panel in that gap is the page looking
        // broken rather than busy.
        Skeleton {
            anchors.fill: parent
            radius: artBox.radius
            shimmer: PlayerState.loading || s.loading
            visible: s.loading || artImg.status !== Image.Ready
        }
        Image {
            id: artImg
            anchors.fill: parent
            source: s.np.art
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
        }
        // ---- sleeve chrome: only while it is a sleeve --------------------
        Item {
            anchors.fill: parent
            opacity: s.p
            // Not over the placeholder: gloss and a spine on a blank plate is
            // a sleeve for a record nobody has put in yet.
            visible: opacity > 0.01 && !s.loading

            Rectangle {   // gloss falling across the board
                anchors.fill: parent
                rotation: 18
                gradient: Gradient {
                    GradientStop { position: 0.00; color: "#00ffffff" }
                    GradientStop { position: 0.30; color: "#0dffffff" }
                    GradientStop { position: 0.44; color: "#00ffffff" }
                    GradientStop { position: 1.00; color: "#00ffffff" }
                }
            }
            Rectangle {   // the corners of a card sleeve fall off
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.00; color: "#2b000000" }
                    GradientStop { position: 0.22; color: "#00000000" }
                    GradientStop { position: 0.80; color: "#00000000" }
                    GradientStop { position: 1.00; color: "#3d000000" }
                }
            }
            Rectangle {   // spine: the fold it is glued along
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: parent.width * 0.055
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: "#59000000" }
                    GradientStop { position: 0.55; color: "#1a000000" }
                    GradientStop { position: 0.80; color: "#14ffffff" }
                    GradientStop { position: 1.00; color: "#00ffffff" }
                }
            }
            Rectangle {   // the mouth the record comes out of
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: parent.width * 0.085
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: "#00000000" }
                    GradientStop { position: 0.70; color: "#40000000" }
                    GradientStop { position: 1.00; color: "#8c000000" }
                }
            }
            // board thickness: the top edge catches the light, the foot does not
            Rectangle { width: parent.width; height: 1; anchors.top: parent.top
                        color: Qt.rgba(1, 1, 1, 0.18) }
            Rectangle { width: parent.width; height: 1; anchors.bottom: parent.bottom
                        color: Qt.rgba(0, 0, 0, 0.70) }
        }

        // No scrim over the picture. Readability over a picture is the
        // over-artwork ink's job (its halo, or an adaptive source), so the
        // picture is shown as it is.
    }

    // ---- the type travels with it ----------------------------------------
    // Three copies, each laid out once at its own size and scaled through the move.
    // Animating pixelSize would reflow every frame (Theme.fs() rounds to whole
    // pixels, changing metrics and wrapping).
    readonly property real bigPx: width > 900 ? 52 : 32
    readonly property real curPx: lerp(bigPx, 22) - 3 * q     // continuous, unrounded
    readonly property real stage1Y: sleeveY + sleeveW + 26
    // Each swap happens across a window in the MIDDLE of its own leg: fully
    // one copy, a short trade, fully the next. The window's width is what the
    // picker's fade control changes — the travel below always takes the whole
    // leg, because that is the movement, and it is not what wanted tuning.
    readonly property real swapW: 0.6
    function swapAt(t) {
        return Math.max(0, Math.min(1, (t - (0.5 - swapW / 2)) / swapW))
    }
    readonly property real swap01: swapAt(p)
    readonly property real handover: swapAt(q)

    // Where the words are, at every point of the second leg. BOTH copies aim
    // at it, so they are always on top of each other and the fade can happen
    // anywhere without showing a seam.
    readonly property real classicTextX: classicPane.metaX
        + (classicPane.metaW - classic.titleW) / 2
    // The poster's type sits at the page margin; the record's sits at its
    // sleeve, which is centred when the window is too narrow for a column
    // beside it. One is not the other, so the type has its own left edge.
    readonly property real headX: lerp(pageX, sleeveX)
    readonly property real textTargetX: headX + (classicTextX - headX) * q

    component TypeBlock: Item {
        property real px: 22                 // native title size — never animated
        property real subPx: 13
        property real boxW: 200
        property int align: Text.AlignLeft
        // 0 = the artist sits at the title's left edge, 1 = centred under it.
        // A real rather than a flag because the record copy has to arrive
        // centred to meet the classic page, without being centred at its own stop.
        property real subCentre: 0
        property bool showMeta: false
        // The picture is a backdrop only where the words stand on it. Off the
        // poster stop it is a sleeve somewhere else and these words are on the
        // page; reading it there maps them outside its texture, the shader
        // clamps, and an adaptive ink or halo samples the poster's picture.
        property bool onArt: false
        readonly property Item wordBackdrop: onArt && artImg.status === Image.Ready
                                             ? artImg : Theme.backdrop
        readonly property real k: s.curPx / px
        // Where this block's TITLE sits, not where its box does. The copies
        // carry different things above the title (the poster has a meta line),
        // so lining up the boxes left the words at different heights.
        readonly property real titleTop: title.y
        readonly property real titleW: title.contentW
        // A centred block scaled about its top-left does NOT keep its text
        // put: half the slack either side scales with it. This is where the
        // words land once that is taken out.
        readonly property real textX: align === Text.AlignHCenter
            ? x + (boxW - titleW) / 2 * k : x
        // scaled about its own top-left, so the anchor below means the same
        // thing whatever size the block is currently passing through
        transformOrigin: Item.TopLeft
        scale: k
        width: boxW
        height: childrenRect.height
        visible: opacity > 0.01
        layer.enabled: s.blurring
        layer.effect: MultiEffect { blurEnabled: true; blur: s.away; blurMax: 24 }

        // Every line on the picture takes the over-artwork ink (its colour,
        // its halo, and its source if it adapts), the others at a lower
        // opacity than the title to keep the hierarchy.
        ScrollText {
            id: meta
            keepTwin: true   // a copy that dissolves in must have its words ready
            width: parent.width
            horizontalAlignment: parent.align
            visible: parent.showMeta && text.length > 0
            text: s.np.metaLine
            ink: "textOverArt"
            backdrop: parent.wordBackdrop
            opacity: 0.8
            tip: true
            font { pixelSize: Theme.fs(11); family: Theme.fontFamily; weight: Theme.weightBase; letterSpacing: 0.6 }
        }
        ScrollText {
            id: title
            keepTwin: true
            // The picture is what this sits on, so it is what an adaptive
            // title reads; until the art arrives it reads Theme.backdrop.
            backdrop: parent.wordBackdrop
            y: meta.visible ? meta.implicitHeight + 6 : 0
            width: parent.width
            liveWidth: true        // it is placed by its own width; see ScrollText
            maxLines: 2
            lineHeight: 1.04
            horizontalAlignment: parent.align
            text: s.np.title
            // The over-artwork ink: the theme's text colour unless the theme
            // gives text over a photograph its own entry, and the one place a
            // blending or adaptive ink has a picture to work against.
            ink: "textOverArt"
            // Tracking is in PIXELS, so a fixed -1.2 and -0.2 are different
            // tracking once both are scaled to the same size: the copies come
            // out different widths and the dissolve shows two of everything.
            // Proportional keeps them metrically identical.
            font { pixelSize: Theme.fs(parent.px); family: Theme.fontFamily
                   weight: Theme.weightBold
                   letterSpacing: -0.023 * parent.px }
        }
        // Placed against the TITLE, not each copy's own box: the copies align
        // their boxes differently, so a box-placed artist would cross the page
        // while the title stands still.
        ScrollText {
            id: sub
            readonly property real titleLeft: parent.align === Text.AlignHCenter
                                              ? (parent.boxW - parent.titleW) / 2 : 0
            y: title.y + title.height + 4
            x: Math.max(0, titleLeft + (parent.titleW - width) / 2 * parent.subCentre)
            width: Math.min(implicitWidth, parent.boxW)
            text: s.np.channel
            ink: "textOverArt"
            backdrop: parent.wordBackdrop
            opacity: 0.8
            tip: true   // elides rather than marquees
            font { pixelSize: Theme.fs(parent.subPx); family: Theme.fontFamily; weight: Theme.weightBase }
        }

    }

    // Where the block sits. The poster and the record copies share a left
    // edge, so only the vertical travels; the classic copy centres in its own
    // full-width box, as the classic page does.
    // the TITLE's top edge, in pane coordinates — every copy hangs off it
    readonly property real anchorY:
        lerp(s.height - GridUi.padBottom - 24 - (poster.height - poster.titleTop) * poster.k, stage1Y)
        + (classicPane.metaY - stage1Y) * q

    TypeBlock {
        id: poster
        px: s.bigPx
        subPx: 16
        onArt: true
        // Wide mode: bounded by side.x, which moves with window height (via rigW,
        // sleeveW <= height * 0.44), or the column declared after this draws over it.
        // Both terms are constant in wide mode so boxW does not animate and rewrap.
        boxW: s.stacked ? s.width - 2 * s.pageX : Math.max(160, side.x - s.headX - 24)
        showMeta: true
        x: s.headX
        y: s.anchorY - titleTop * k
        opacity: 1 - s.swap01
    }
    TypeBlock {
        id: record
        px: 22
        subPx: 13
        subCentre: s.q          // left at its own stop, centred by the handover
        boxW: Math.min(s.width - s.sleeveX - GridUi.padRight - 30, 460)
        // Travels to sit exactly where the classic copy's text lands, so the
        // two are the same words at the same size in the same place while they
        // swap — the dissolve has nothing left to give away.
        x: s.textTargetX
        y: s.anchorY - titleTop * k
        opacity: s.swap01 * (1 - s.handover)
    }
    TypeBlock {
        id: classic
        px: 19
        subPx: 14
        subCentre: 1
        boxW: classicPane.metaW
        align: Text.AlignHCenter
        // its own box is the full width the classic page centres in, so it sits
        // where that page puts it rather than travelling with the other two
        // travels with the record copy, and cancels the drift a centred block
        // gets from being scaled about its top-left
        x: s.textTargetX - (boxW - titleW) / 2 * k
        y: s.anchorY - titleTop * k
        opacity: s.handover
    }

    // ---- the reading column arrives beside the record --------------------
    Item {
        id: side
        x: s.stacked ? GridUi.padLeft + 14 : s.sleeveX + s.rigW + 46
        // Stacked, this sits under the title block — so it is measured from
        // that block, not from a number that assumed one line.
        y: s.stacked ? s.anchorY + record.height * record.k + 22 : GridUi.padTop + 36
        width: s.stacked ? s.width - 2 * (GridUi.padLeft + 14)
                         : s.width - x - GridUi.padRight - 30
        height: s.height - y - GridUi.padBottom - 20
        opacity: s.late * s.leaving
        visible: opacity > 0.01 && width > 150 && height > 80

        NpToggle { id: sideToggle; np: s.np }
        Item {
            y: sideToggle.height + 20
            width: parent.width
            height: parent.height - y

            Flickable {
                id: infoFlick
                anchors.fill: parent
                visible: s.np.tab === 0
                contentHeight: infoCol.implicitHeight
                clip: true
                WheelScroll { target: infoFlick; chain: s.stepBy }
                Column {
                    id: infoCol
                    width: infoFlick.width
                    spacing: 18
                    NpFacts { np: s.np; width: parent.width; loading: s.loading }
                    // the description, before there is one: ragged lines, the
                    // last one short, because that is what a paragraph does
                    Column {
                        visible: s.loading
                        width: parent.width
                        spacing: 7
                        Repeater {
                            model: 4
                            Skeleton {
                                required property int index
                                width: parent.width * [0.94, 0.88, 0.96, 0.52][index]
                                height: 9
                                radius: 3
                            }
                        }
                    }
                    InkText {
                        width: parent.width
                        visible: !s.loading && text.length > 0
                        wrapMode: Text.Wrap
                        lineHeight: 1.45
                        text: s.np.description
                        ink: "text"
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightBase }
                    }
                }
            }
            NpWords {
                anchors.fill: parent
                visible: s.np.tab === 1
                np: s.np
                fontSize: 16
                chain: s.stepBy
            }
            // Both belong to the lyrics tab: np.loading is the lyrics fetch,
            // so on the info tab they would sit over the facts.
            InkText {
                visible: s.np.tab === 1 && !s.np.loading && s.np.emptyBody.length > 0
                text: s.np.emptyBody
                ink: "text"
                font { pixelSize: Theme.fs(13); family: Theme.fontFamily; weight: Theme.weightBase }
            }
            Spinner { running: s.np.tab === 1 && s.np.loading }
        }
    }

    // ---- the words, at the two ends ---------------------------------------
    // The record has a column and a choice of what to put in it. The poster
    // and the classic page have neither, so the words are a plain on/off there —
    // not the other half of a slider whose first half has nowhere to go.
    readonly property real atEnds: Math.max(Math.max(0, 1 - p / 0.3),
                                            Math.max(0, (q - 0.7) / 0.3))

    // On the poster the words need the picture to give way; PosterWords does
    // it with a stripe across the middle.
    readonly property real posterWords: Math.max(0, 1 - p / 0.3) * (1 - q)
                                        * (np.showWords ? 1 : 0)
    PosterWords {
        anchors.fill: parent
        np: s.np
        // s.anchorY IS the title's top. Every TypeBlock is placed as
        // `y: s.anchorY - titleTop * k`, so block.y + titleTop*k comes back to
        // s.anchorY whichever copy is showing.
        titleTop: s.anchorY
        opacity: s.posterWords * (s.np.hasWords ? 1 : 0)
        visible: opacity > 0.01
    }

    SelectTab {   // the narrow layout's stand-in for Info | Lyrics
        id: wordsBtn
        x: s.pageX          // the page margin, not the record's
        y: 26
        height: 30
        // the toggles style, as the two-way toggle takes; a lone word has
        // no track for a segment to travel, so that one reads as a pill
        style: Theme.toggles === "segment" ? "pill" : Theme.toggles
        active: s.np.showWords
        hover: wordsMa.containsMouse; pressed: wordsMa.pressed
        label: s.np.loading ? "Lyrics…" : (s.np.noLyrics ? "No lyrics" : "Lyrics")
        fontSize: 11
        weight: Theme.weightMedium
        width: implicitWidth
        opacity: s.atEnds * (s.np.noLyrics ? 0.45 : 1)
        visible: opacity > 0.01 && s.np.vid.length > 0
        MouseArea {
            id: wordsMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: !s.np.noLyrics
            onClicked: s.np.showWords = !s.np.showWords
        }
    }

    Text {   // the poster does not look like it goes anywhere
        style: Theme.textStyle; styleColor: Theme.textStyleColor
        anchors.right: parent.right
        anchors.rightMargin: 26
        anchors.verticalCenter: parent.verticalCenter
        opacity: (1 - s.p) * 0.45 * (1 - s.q)
        visible: opacity > 0.02
        text: "‹"
        color: "#ffffff"
        font { pixelSize: Theme.fs(30); family: Theme.fontFamily; weight: Theme.weightBase }
    }

    // ---- and then the classic page ---------------------------------------
    Classic {
        id: classicPane
        np: s.np
        width: s.width
        height: s.height
        coverVisible: false          // the travelling picture is its cover
        metaVisible: false           // and the travelling words are its title
        // It has lyrics of its own, so it fades in with the handover rather
        // than drawing them over the poster's.
        opacity: s.handover
        visible: opacity > 0.01
    }

    // ---- the ways to move it ---------------------------------------------
    // Drag: the picture follows the hand and lets go to the nearer end.
    DragHandler {
        target: null
        xAxis.enabled: true
        yAxis.enabled: false
        property real from: 0
        onActiveChanged: {
            if (active) { s.live = true; from = s.phase }
            else s.settle()
        }
        onTranslationChanged: if (active)
            s.phase = Math.max(0, Math.min(2, from - translation.x / (s.width * 0.55)))
    }
    // A wheel is not a hand: one notch commits rather than leaving a fraction
    // to guess at. Listens only at the ends, so it never fights the column.
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        // only at rest, so a notch never leaves the page half way across
        enabled: Math.abs(s.phase - Math.round(s.phase)) < 0.02
        onWheel: (e) => s.stepBy(e.angleDelta.y !== 0 ? e.angleDelta.y : -e.angleDelta.x)
    }
}
