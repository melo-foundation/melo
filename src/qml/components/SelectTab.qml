import QtQuick
import ".."

// One selectable in a strip (view tab, chip, page tab), drawn in the theme's
// style for its kind: filled, pill, underline, segment (words only; the strip
// draws track and pill) or button. The site names the kind; no strip draws its own.
Surface {
    id: tab
    property string label
    property bool active: false
    property bool hover: false
    property bool pressed: false
    property string style: "filled"
    property real fontSize: 12
    property int weight: Theme.weightBase
    // a chip standing in for one still loading: no fill
    property bool blank: false
    property real textOpacity: 1
    readonly property bool line: style === "underline"
    readonly property bool pill: style === "pill"
    readonly property bool segment: style === "segment"
    readonly property bool button: style === "button"
    implicitWidth: txt.implicitWidth + (line ? 32 : segment ? 24 : 20)
    radius: line ? 0 : (pill ? Theme.pill(height / 2) : Theme.radiusMd)
    role: (blank || line || segment) ? ""
        : button ? Theme.faceOf("button", hover, pressed, active)
        : active ? "selected"
        : hover ? "hover"
        : (pill ? "button" : "")
    borderWidth: button && !blank ? 1 : 0
    borderRole: hover && !active ? "borderStrong" : "border"
    InkText {
        id: txt
        anchors.centerIn: parent
        text: tab.label
        opacity: tab.textOpacity
        // a pill reads as a button and keeps its words at full ink; the
        // others dim what is not chosen. SegmentTrack paints the accent under
        // its active tab, so that tab takes textOnAccent; selected ink would
        // vanish on pale accents in dark themes and dark ones in light themes.
        ink: tab.active ? (tab.segment ? "textOnAccent" : tab.line ? "text" : tab.button ? "textOnActive" : "textOnSelected")
                        : (tab.pill ? "text" : (tab.hover ? "textSoft" : "textDim"))
        anchors.horizontalCenterOffset: tab.button ? Theme.pressShift(tab.pressed) : 0
        anchors.verticalCenterOffset: tab.button ? Theme.pressShift(tab.pressed) : 0
        font { pixelSize: Theme.fs(tab.fontSize); family: Theme.fontFamily
               weight: tab.active && !tab.pill ? Theme.weightMedium : tab.weight }
    }
    Surface {
        visible: tab.line && tab.active
        anchors.bottom: parent.bottom
        width: parent.width; height: 2
        role: "tabLine"
    }
}
