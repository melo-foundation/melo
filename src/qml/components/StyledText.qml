import QtQuick

// Text filled by styled.frag: HueLumText's coverage trick with a procedural
// fill in place of the backdrop.
Item {
    id: root
    property string text: ""
    property font font
    property int horizontalAlignment: Text.AlignLeft
    property int verticalAlignment: Text.AlignTop
    property real lineHeight: 1.0
    property int wrapMode: Text.NoWrap
    property int maximumLineCount: 1
    property int elide: Text.ElideNone
    property string kind: "rainbow"
    property var params
    property var layers: null
    property color colourA: "#ffffff"
    property bool local: false

    implicitWidth: glyphs.implicitWidth
    implicitHeight: glyphs.implicitHeight

    // An ink's opacity is set here, one level above the fill (see InkTwin),
    // so a stack is flattened here before it is applied, as in StyledFill.
    layer.enabled: opacity < 1 && layers !== null && layers !== undefined && layers.length > 1

    Item {
        width: 0; height: 0; clip: true
        Text {
            id: glyphs
            width: root.width
            height: root.height
            text: root.text
            font: root.font
            color: "#ffffff"
            horizontalAlignment: root.horizontalAlignment
            verticalAlignment: root.verticalAlignment
            lineHeight: root.lineHeight
            lineHeightMode: Text.ProportionalHeight
            wrapMode: root.wrapMode
            maximumLineCount: root.maximumLineCount
            elide: root.elide
            layer.enabled: true
        }
    }
    StyledFill {
        anchors.fill: parent
        mask: glyphs
        kind: root.kind
        params: root.params
        colourA: root.colourA
        layers: root.layers
        local: root.local
        lineHeightPx: glyphs.lineCount > 0 ? glyphs.contentHeight / glyphs.lineCount : 0
    }
}
