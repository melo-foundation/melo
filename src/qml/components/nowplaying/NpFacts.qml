import QtQuick
import ".."
import "../.."

// The facts as a list: label left, value right, a hairline between.
Column {
    id: root
    property var np
    property int labelSize: 12
    property int valueSize: 12
    property bool rules: true
    spacing: 0

    // Nothing is known yet: rows of the shape the facts will take, so the
    // column has a size before it has anything to say. The count is what a
    // track usually carries — length, views, likes, published, channel.
    property bool loading: false

    Repeater {
        model: root.loading ? 5 : 0
        Item {
            required property int index
            width: root.width
            height: 30
            Surface {
                width: parent.width; height: 1
                role: "border"
                visible: root.rules && parent.index > 0
            }
            Skeleton {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 52 + ((parent.index * 23) % 26)
                height: 9
                radius: 3
            }
            Skeleton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 64 + ((parent.index * 37) % 48)
                height: 9
                radius: 3
            }
        }
    }

    Repeater {
        model: root.loading ? [] : (root.np ? root.np.facts : [])
        Item {
            required property var modelData
            required property int index
            width: root.width
            height: 30
            Surface {
                width: parent.width; height: 1
                role: "border"
                visible: root.rules && parent.index > 0
            }
            InkText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.k
                ink: "textFaint"
                font { pixelSize: Theme.fs(root.labelSize); family: Theme.fontFamily; weight: Theme.weightBase }
            }
            InkText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.7
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                text: parent.modelData.v
                ink: "textDim"
                font { pixelSize: Theme.fs(root.valueSize); family: Theme.fontFamily; weight: Theme.weightBase }
            }
        }
    }
}
