import QtQuick
import ".."

// The effect an ink asks for, drawn beneath its words: Halo with the label
// as the shape. `label` is the Text being decorated; it is never touched.
Halo {
    id: th
    property Item label: null
    // beside the label (ScrollText) or inside it (InkText, which is a Text
    // and says so — the halo's parent is its Loader, not the label)
    property bool inside: false
    x: label && !inside ? label.x : 0
    y: label && !inside ? label.y : 0
    width: label ? label.width : 0
    height: label ? label.height : 0
    // Relative to the type: a size unit is 6% of the font's pixel size, so
    // 1 is a hairline on a 12px row and a real 3px stroke on a 52px title
    unit: label ? label.font.pixelSize * 0.06 : 1
    shape: label ? words : null
    Component {
        id: words
        Text {
            text: th.label.text
            font: th.label.font
            horizontalAlignment: th.label.horizontalAlignment
            verticalAlignment: th.label.verticalAlignment
            wrapMode: th.label.wrapMode
            elide: th.label.elide
            maximumLineCount: th.label.maximumLineCount
            lineHeight: th.label.lineHeight
            lineHeightMode: th.label.lineHeightMode
            color: parent.tint
        }
    }
}
