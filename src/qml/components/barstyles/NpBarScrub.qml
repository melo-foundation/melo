import QtQuick
import ".."
import "../.."

// The seek surface, on its own so eight bars can place it eight ways. Owns
// the whole scrub contract: drag target beats pending seek beats engine
// position, so releasing never snaps back to a stale time.
Item {
    id: root
    property real trackH: 6
    property real hoverH: 9
    property bool showTimes: true
    property bool showTotal: true      // the total beside the elapsed
    property bool showBubble: true
    // The groove is a role, not a hover state: an inset control. Every part
    // is a role reader, so a fill or contrast on the scrubber key or an ink
    // reaches the bar as it reaches everything else.
    property string trackRole: "scrubberTrack"
    property string timeInk: "textSoft"
    property int timeSize: 12
    // Sit the track on the item's bottom edge instead of in its middle, so a
    // bar that runs along the window's edge is actually ON it — and so growing
    // under the pointer grows upward, away from the edge, rather than half
    // over it.
    property bool alignBottom: false
    // the track's corner: a pill by default, or what the document says
    property real trackRadius: -1
    // Glides the ~4Hz position ticks. A click just ahead of the playhead and a
    // seek handover look the same as a tick, so the gate is the event: anything from
    // a seek or a track change snaps.
    property bool glide: false
    property bool holdAnims: false      // a resize in flight: snap
    readonly property bool active: pMa.containsMouse || pMa.scrubbing
    // A knob, if the theme wants one, riding the fill's end. With it the
    // fill and the drag run between the knob's two rests, as a slider's do;
    // without it they run rail end to rail end.
    readonly property bool hasKnob: Theme.scrubberKnobSize > 0
    readonly property real inset: hasKnob ? Theme.ctl(Theme.scrubberKnobInset) : 0

    implicitHeight: 24

    function fmt(s) {
        if (!isFinite(s) || s <= 0) return "0:00"
        const m = Math.floor(s / 60), sec = Math.floor(s % 60)
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    InkText {
        id: elapsed
        visible: root.showTimes
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? Math.max(Theme.sp(36), implicitWidth) : 0
        horizontalAlignment: Text.AlignHCenter
        text: root.fmt(pMa.scrubbing ? pMa.scrubPos : PlayerState.position)
        ink: pMa.scrubbing ? "text" : root.timeInk
        font { pixelSize: Theme.fs(root.timeSize); family: Theme.fontFamily; weight: Theme.weightBase }
    }
    InkText {
        id: total
        visible: root.showTimes && root.showTotal
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? Math.max(Theme.sp(36), implicitWidth) : 0
        horizontalAlignment: Text.AlignHCenter
        text: root.fmt(PlayerState.duration)
        ink: root.timeInk
        font { pixelSize: Theme.fs(root.timeSize); family: Theme.fontFamily; weight: Theme.weightBase }
    }

    Surface {
        id: track
        anchors.left: elapsed.right
        anchors.leftMargin: root.showTimes ? 8 : 0
        anchors.right: total.left
        anchors.rightMargin: root.showTimes ? 8 : 0
        y: root.alignBottom ? root.height - height : GridUi.centreIn(root.height, height)
        height: GridUi.snap(root.active && Theme.scrubberGrow ? root.hoverH : root.trackH)
        // Square where it runs along the window's edge: pill ends read as the
        // line stopping short of the corner rather than meeting it.
        radius: root.trackRadius >= 0 ? root.trackRadius : root.alignBottom ? 0 : height / 2
        objectName: "scrubTrack"
        role: root.trackRole
        // track width changes (window resize) snap the fill — the glide
        // would lag it behind the layout
        onWidthChanged: { wAnim.stop(); fill.width = fill.targetW }
        Behavior on height { NumberAnimation { duration: Theme.motionFast; easing.type: Theme.motionEase } }

        // scrub > pending seek (anti snap-back) > engine position
        readonly property real shownPos: pMa.scrubbing ? pMa.scrubPos
                                       : pMa.pendingSeek >= 0 ? pMa.pendingSeek
                                       : PlayerState.position

        Surface {   // the played fill
            id: fill
            height: parent.height
            radius: parent.radius
            role: "scrubber"
            readonly property real targetW: PlayerState.duration > 0
                   ? root.inset + (track.width - 2 * root.inset) * Math.min(1, track.shownPos / PlayerState.duration) : 0
            Binding { target: fill; property: "width"; value: fill.targetW; when: !root.glide }
            // true while the position is not the clock: a track change and a
            // seek both move it in steps that are nobody's idea of playback
            property bool settling: false
            Timer { id: settleTimer; interval: 400; onTriggered: fill.settling = false }
            function settle() { settling = true; settleTimer.restart() }
            Connections {
                target: PlayerState
                function onTrackChanged() { fill.settle(); wAnim.stop(); fill.width = fill.targetW }
            }
            onTargetWChanged: {
                if (!root.glide) return
                const d = targetW - width
                if (!root.holdAnims && !pMa.scrubbing && !settling && pMa.pendingSeek < 0
                    && d > 0 && d < track.width * 0.08) {
                    wAnim.stop(); wAnim.to = targetW; wAnim.start()
                } else {
                    wAnim.stop(); width = targetW
                }
            }
            // grab instant: kill the glide mid-flight
            onSettlingChanged: if (settling) { wAnim.stop(); width = targetW }
            NumberAnimation { id: wAnim; target: fill; property: "width"; duration: 250 }
        }
        Connections {
            target: root
            function onHoldAnimsChanged() { if (root.holdAnims) { wAnim.stop(); fill.width = fill.targetW } }
        }
        Surface {
            objectName: "scrubKnob"
            visible: root.hasKnob
            y: (parent.height - height) / 2
            // Kept on the rail: centred on the fill's end, a thumb would hang
            // half off the rail at nought and at full. A round one loses a
            // crescent there; a capsule wider than it is tall loses a cap,
            // which is most of what makes it read as a thumb at all.
            x: Math.max(0, Math.min(parent.width - width, fill.width - width / 2))
            height: GridUi.knobOn(Theme.ctl(Theme.scrubberKnobSize), parent.height)
            width: Math.round(height * Theme.scrubberKnobAspect)
            radius: Theme.knobRadius(Theme.scrubberKnobShape, Math.min(width, height))
            role: "scrubberKnob"
        }

        Surface {   // hover/scrub time bubble
            visible: root.showBubble && root.active
            x: Math.max(0, Math.min(parent.width - width,
               (pMa.scrubbing ? pMa.scrubX : pMa.mouseX) - width / 2))
            y: -26
            width: bubbleText.implicitWidth + 12
            height: 20
            radius: Theme.radiusMd
            role: "tooltip"
            InkText {
                id: bubbleText
                anchors.centerIn: parent
                text: root.fmt(pMa.scrubbing ? pMa.scrubPos : pMa.posAt(pMa.mouseX))
                ink: "text"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily; weight: Theme.weightBase }
            }
        }

        MouseArea {
            id: pMa
            anchors.fill: parent
            anchors.topMargin: -8; anchors.bottomMargin: -8
            hoverEnabled: true
            property bool scrubbing: false
            property real scrubPos: 0
            property real scrubX: 0
            // released target stands until the engine catches up
            property real pendingSeek: -1
            Connections {
                target: PlayerState
                function onPositionChanged() {
                    if (pMa.pendingSeek >= 0
                        && Math.abs(PlayerState.position - pMa.pendingSeek) < 1.5)
                        pMa.pendingSeek = -1
                }
                function onTrackChanged() { pMa.pendingSeek = -1 }
            }
            Timer { id: seekTimeout; interval: 1200; onTriggered: pMa.pendingSeek = -1 }
            // letting go of the seek target is itself a step: the fill moves
            // from where the click asked for to where the engine landed
            onPendingSeekChanged: if (pendingSeek < 0) fill.settle()
            function posAt(x) {
                return PlayerState.duration > 0
                       ? Math.max(0, Math.min(1, (x - root.inset) / Math.max(1, track.width - 2 * root.inset))) * PlayerState.duration : 0
            }
            onPressed: (m) => {
                if (PlayerState.duration <= 0) return
                scrubbing = true; scrubX = m.x; scrubPos = posAt(m.x)
            }
            onPositionChanged: (m) => {
                if (!scrubbing) return
                scrubX = m.x; scrubPos = posAt(m.x)
            }
            onReleased: {
                if (!scrubbing) return
                scrubbing = false
                pendingSeek = scrubPos
                seekTimeout.restart()
                Player.seek(scrubPos)
            }
            onCanceled: scrubbing = false
        }
    }
}
