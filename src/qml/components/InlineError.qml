import QtQuick
import ".."
import "errorui.js" as ErrorUi

// A failure inside a page or a form, in ErrorPanel's look: the alert glyph,
// the words in the text ink, then the answers in errorui.js's order.
// `centred`: a page's whole content failed (Home, a playlist), a size up.
Item {
    id: box
    property string message
    // [{ id, label }], the main answer first
    property var actions: []
    property bool centred: false
    // the colour the glyph sits on, for its contrast
    property color face: Theme.roleColour("page")
    property string namePrefix: objectName + "_"
    signal triggered(string id)

    readonly property real fs: centred ? 14 : 11
    readonly property var ordered: ErrorUi.ordered(actions)
    readonly property string primary: ErrorUi.primaryOf(actions)
    visible: message.length > 0
    implicitWidth: centred ? Math.min(Theme.ctl(420), parent ? parent.width - Theme.gap(32) : Theme.ctl(420))
                           : glyph.width + Theme.gap(6) + line.implicitWidth
                             + (btns.width > 0 ? Theme.gap(8) + btns.width : 0)
    implicitHeight: centred ? lineRow.height + (btns.width > 0 ? Theme.gap(12) + btns.height : 0)
                            : Math.max(line.height, btns.height)

    Item {
        id: lineRow
        width: box.centred ? Math.min(box.width, glyph.width + Theme.gap(6) + line.implicitWidth) : box.width - (btns.width > 0 ? Theme.gap(8) + btns.width : 0)
        height: line.height
        x: box.centred ? (box.width - width) / 2 : 0
        y: box.centred ? 0 : (box.height - height) / 2
        // the glyph centres on the first line's capitals
        TextMetrics { id: cap; font: line.font; text: "H" }
        Icon {
            id: glyph
            objectName: "alertGlyph"
            name: "alert"
            size: Theme.glyph(box.centred ? 16 : 12)
            color: ErrorUi.glyphOn(Theme.danger, box.face)
            y: line.baselineOffset - cap.tightBoundingRect.height / 2 - height / 2
        }
        InkText {
            id: line
            objectName: box.objectName + "Text"
            x: glyph.width + Theme.gap(6)
            width: Math.min(implicitWidth, parent.width - x)
            text: box.message
            ink: "text"
            wrapMode: Text.Wrap
            font { pixelSize: Theme.fs(box.fs); family: Theme.fontFamily }
        }
    }
    Row {
        id: btns
        spacing: Theme.gap(8)
        x: box.centred ? (box.width - width) / 2 : box.width - width
        y: box.centred ? lineRow.height + Theme.gap(12) : (box.height - height) / 2
        Repeater {
            model: box.ordered
            delegate: PushButton {
                required property var modelData
                objectName: box.namePrefix + modelData.id
                label: modelData.label
                accent: box.centred && modelData.id === box.primary
                labelColor: accent ? ErrorUi.inkOn(Theme.accent) : "transparent"
                pad: box.centred ? 24 : 20
                fontSize: box.centred ? 12 : 11
                onClicked: box.triggered(modelData.id)
            }
        }
    }
}
