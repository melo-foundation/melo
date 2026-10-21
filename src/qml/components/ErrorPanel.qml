import QtQuick
import ".."
import "errorui.js" as ErrorUi

// Every error melo shows: what went wrong in one line, then the answers in
// errorui.js's order. `blocking` is the dialog size (the line wraps, the
// buttons sit under it, Report… at the left edge); otherwise the bar size, one
// row. The face is the dialog role made opaque, so its words read the same on
// glass themes as on solid ones.
Surface {
    id: panel
    property string message
    property bool blocking: false
    // [{ id, label, enabled? }], the main answer first
    property var actions: []
    property string namePrefix: "error_"
    property string messageName: ""
    // a notice that is not a failure goes without the alert glyph
    property bool alert: true
    // the widest a bar grows to; it is as wide as its content below that
    property real maxWidth: 520
    signal triggered(string id)

    readonly property var ordered: ErrorUi.ordered(actions)
    readonly property string primary: ErrorUi.primaryOf(actions)
    readonly property real padX: Theme.gap(blocking ? 18 : 12)
    readonly property real padY: Theme.gap(blocking ? 16 : 7)
    readonly property real btnPad: blocking ? 24 : 18
    readonly property real btnFont: blocking ? 12 : 11

    readonly property var faceRole: Theme.role("dialog")
    role: ""
    color: Qt.rgba(faceRole.colour.r, faceRole.colour.g, faceRole.colour.b, 1)
    radius: blocking ? Theme.radiusLg : Theme.radiusMd
    borderWidth: 1
    borderRole: "border"

    implicitWidth: blocking ? maxWidth
        : Math.min(maxWidth, padX * 2 + iconW + line.implicitWidth + Theme.gap(12) + buttons.implicitWidth)
    implicitHeight: blocking
        ? padY * 2 + Math.max(icon.height, line.height) + Theme.gap(16) + Theme.btnH
        : padY * 2 + Math.max(Theme.btnH, line.height)

    readonly property real iconW: alert ? icon.width + Theme.gap(8) : 0
    // the glyph centres on the first line's capitals, however many lines wrap below it
    TextMetrics { id: cap; font: line.font; text: "H" }
    Icon {
        id: icon
        objectName: "alertGlyph"
        visible: panel.alert
        x: panel.padX
        y: line.y + line.baselineOffset - cap.tightBoundingRect.height / 2 - height / 2
        name: "alert"
        size: Theme.glyph(panel.blocking ? 16 : 14)
        color: ErrorUi.glyphOn(Theme.danger, panel.color)
    }
    InkText {
        id: line
        objectName: panel.messageName
        x: panel.padX + panel.iconW
        y: panel.blocking ? panel.padY : (panel.height - height) / 2
        width: panel.blocking ? panel.width - x - panel.padX
                              : panel.width - x - Theme.gap(12) - buttons.width - panel.padX
        text: panel.message
        ink: "text"
        wrapMode: Text.Wrap
        maximumLineCount: panel.blocking ? 6 : 3
        elide: Text.ElideRight
        font { pixelSize: Theme.fs(panel.blocking ? 13 : 12); family: Theme.fontFamily }
    }

    component Btn: PushButton {
        required property var modelData
        objectName: panel.namePrefix + modelData.id
        label: modelData.label
        accent: modelData.id === panel.primary
        labelColor: accent ? ErrorUi.inkOn(Theme.accent) : "transparent"
        enabled: modelData.enabled !== false
        opacity: enabled ? 1 : 0.5
        pad: panel.btnPad; fontSize: panel.btnFont
        onClicked: panel.triggered(modelData.id)
    }

    // bar: one row, right of the line; dialog: Report… left, the rest right
    Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: panel.padX
        y: panel.blocking ? panel.height - panel.padY - Theme.btnH : (panel.height - Theme.btnH) / 2
        spacing: Theme.gap(8)
        Repeater {
            model: panel.blocking ? panel.ordered.filter((a) => a.id !== "report") : panel.ordered
            delegate: Btn {}
        }
    }
    Row {
        visible: panel.blocking
        x: panel.padX
        y: buttons.y
        Repeater {
            model: panel.blocking ? panel.ordered.filter((a) => a.id === "report") : []
            delegate: Btn {}
        }
    }
}
