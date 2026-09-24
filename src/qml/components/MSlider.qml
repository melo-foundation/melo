import QtQuick
import ".."

// The app's slider.
Item {
    id: sld

    property real from: 0
    property real to: 1
    property real step: 0
    property real value: 0
    // The Flickable to hold still while this takes focus, if any: focusing a
    // row makes an enclosing Flickable scroll it into view, which yanks the
    // track out from under the cursor mid-drag.
    property Flickable holdFlick: null
    signal committed(real v)
    // the pointer is down on it: `live` moves, nothing has been committed yet
    readonly property bool dragging: dragMa.pressed
    // The role and size family this slider draws with. The volume cell asks
    // for "volume", so a theme can shape the volume rail and thumb without
    // changing every slider in Settings.
    property string parts: "slider"
    readonly property string trackRole: parts + "Track"
    readonly property string fillRole: parts + "Fill"
    readonly property string knobRole: parts + "Knob"
    readonly property real partTrackH: parts === "volume" ? Theme.volumeTrackHeight : Theme.sliderTrackHeight
    readonly property real partKnobSize: parts === "volume" ? Theme.volumeKnobSize : Theme.sliderKnobSize
    readonly property real partKnobAspect: parts === "volume" ? Theme.volumeKnobAspect : Theme.sliderKnobAspect
    readonly property string partKnobShape: parts === "volume" ? Theme.volumeKnobShape : Theme.sliderKnobShape
    readonly property string partTrackShape: parts === "volume" ? Theme.volumeTrackShape : Theme.sliderTrackShape
    readonly property real partKnobInset: parts === "volume" ? Theme.volumeKnobInset : Theme.sliderKnobInset

    width: Theme.sp(150); height: Theme.sp(24)

    // keyboard: Tab to focus, arrows to nudge by step (or 1/20th of the range
    // when step is 0). Each press commits.
    activeFocusOnTab: true
    readonly property real _inc: step > 0 ? step : (to - from) / 20
    function _nudge(dir) {
        let v = Math.max(from, Math.min(to, live + dir * _inc))
        if (step > 0) v = Math.round(v / step) * step
        live = v; committed(v)
    }
    Keys.onLeftPressed: _nudge(-1)
    Keys.onDownPressed: _nudge(-1)
    Keys.onRightPressed: _nudge(1)
    Keys.onUpPressed: _nudge(1)

    // `live` is the working/displayed value. It follows `value` ONLY when not
    // dragging, so a release never snaps back to the old bound value if the
    // committed write doesn't re-notify the binding.
    property real live: value
    onValueChanged: if (!dragMa.pressed) live = value
    property real shown: live
    // fill/handle position clamped: a stored value outside the range (option
    // shared across bg types with different ranges) must not draw past the track
    readonly property real frac: to > from
        ? Math.max(0, Math.min(1, (shown - from) / (to - from))) : 0
    // the knob's centre travels from `inset` to `width - inset`; the fill
    // ends under it, and a press maps back along the same run
    readonly property real inset: Theme.ctl(sld.partKnobInset)
    readonly property real run: Math.max(1, width - 2 * inset)
    readonly property real knobAt: inset + run * frac
    function valAt(x) {
        let v = from + (to - from) * Math.max(0, Math.min(1, (x - inset) / run))
        if (step > 0) v = Math.round(v / step) * step
        return Math.max(from, Math.min(to, v))
    }

    // on whole device pixels, the knob the track's parity — see GridUi.knobOn
    readonly property real trackH: GridUi.snap(Theme.ctl(sld.partTrackH))
    readonly property real knobSize: GridUi.knobOn(Theme.ctl(sld.partKnobSize), Theme.ctl(sld.partTrackH))
    readonly property real trackY: GridUi.centreIn(height, trackH)

    Surface {
        y: sld.trackY
        width: parent.width; height: sld.trackH; radius: Theme.trackRadius(sld.partTrackShape, height)
        objectName: "sliderTrack"
        role: sld.trackRole
    }
    Surface {
        y: sld.trackY
        width: Math.max(0, Math.min(parent.width, sld.knobAt))
        height: sld.trackH; radius: Theme.trackRadius(sld.partTrackShape, height)
        objectName: "sliderFill"
        role: sld.fillRole
    }
    Surface {
        y: sld.trackY + (sld.trackH - height) / 2
        x: sld.knobAt - width / 2
        width: Math.round(sld.knobSize * sld.partKnobAspect); height: sld.knobSize
        radius: Theme.knobRadius(sld.partKnobShape, Math.min(width, height))
        objectName: "sliderKnob"
        role: sld.knobRole
        // the focus ring sits OUTSIDE the knob, in the slider's own fill: a
        // border on the knob itself read as the knob changing colour
        Surface {
            anchors.centerIn: parent
            width: parent.width + 6; height: parent.height + 6
            radius: Theme.knobRadius(sld.partKnobShape, Math.min(width, height))
            visible: sld.activeFocus
            role: ""
            borderRole: sld.fillRole
            borderWidth: 1
        }
    }
    MouseArea {
        id: dragMa
        anchors.fill: parent
        anchors.topMargin: -4; anchors.bottomMargin: -4
        // keep the drag even when the cursor leaves the slider — else the
        // parent Flickable steals it (drag stops + list scrolls)
        preventStealing: true
        onPressed: (m) => {
            // focus for arrow-key support, but a Flickable would scroll the
            // newly-focused row into view — hold contentY
            const cy = sld.holdFlick ? sld.holdFlick.contentY : 0
            sld.forceActiveFocus()
            if (sld.holdFlick) sld.holdFlick.contentY = cy
            sld.live = sld.valAt(m.x)
        }
        onPositionChanged: (m) => { if (pressed) sld.live = sld.valAt(m.x) }
        onReleased: sld.committed(sld.live)   // live already holds it; no snap-back
    }
}
