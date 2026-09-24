import QtQuick
import ".."

// Spatial controls need a picture, not eight unrelated numeric sliders.
Column {
    id: root
    objectName: "imageFillSettings"
    property var picker: null
    readonly property int fit: picker ? picker.optionOf("fit") : 0
    readonly property int anchor: picker ? picker.optionOf("anchor") : 0
    readonly property bool sliced: fit === 5
    readonly property real focusX: picker && picker.optionOf("focusX") >= 0 ? picker.optionOf("focusX") : (anchor % 3) / 2
    readonly property real focusY: picker && picker.optionOf("focusY") >= 0 ? picker.optionOf("focusY") : Math.floor(anchor / 3) / 2
    spacing: Theme.gap(8)

    function setFit(value) {
        if (!picker) return
        // A newly fitted image normally belongs to this control. Window and
        // scroll space remain available; nine-slice is always item-local.
        if ((fit === 0 && value !== 0) || value === 5) picker.layerSpace = "item"
        picker.setOption("fit", value)
        picker.livePreview()
    }
    function pick(x, y) {
        if (!picker || sliced) return
        picker.setOption("focusX", Math.max(0, Math.min(1, x)))
        picker.setOption("focusY", Math.max(0, Math.min(1, y)))
    }
    function resetFocus() {
        if (!picker) return
        picker.setOption("focusX", -1); picker.setOption("focusY", -1)
    }
    function cutPair(first, last, size) {
        const factor = Math.min(1, Math.max(size - 1, 0) / Math.max(first + last, 0.0001))
        return [first * factor, last * factor]
    }

    Grid {
        width: parent.width
        columns: 3; spacing: Theme.gap(3)
        Repeater {
            model: Theme.imageFits
            Surface {
                required property int index
                required property string modelData
                objectName: "imageFit_" + index
                readonly property bool on: root.fit === index
                width: (root.width - Theme.gap(6)) / 3; height: Theme.ctl(23)
                radius: Theme.radiusSm
                role: on ? "accent" : Theme.faceOf("button", fitMouse.containsMouse)
                borderRole: on ? "accent" : "border"; borderWidth: 1
                activeFocusOnTab: true
                Accessible.role: Accessible.Button; Accessible.name: modelData
                Accessible.checkable: true; Accessible.checked: on
                Accessible.onPressAction: root.setFit(index)
                Keys.onSpacePressed: root.setFit(index)
                Keys.onReturnPressed: root.setFit(index)
                InkText { anchors.centerIn: parent; text: parent.modelData
                          ink: parent.on ? "textOnAccent" : "textDim"; font.pixelSize: Theme.fs(11) }
                MouseArea { id: fitMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.setFit(parent.index) }
            }
        }
    }
    Row {
        width: parent.width
        spacing: Theme.gap(8)
        Column {
            id: anchorBox
            width: Theme.ctl(72)
            visible: !root.sliced
            spacing: Theme.gap(4)
            InkText { text: "anchor"; font.pixelSize: Theme.fs(11); ink: "textDim"; height: Theme.ctl(18) }
            Grid {
                columns: 3; spacing: Theme.ctl(3)
                Repeater {
                    model: ["↖", "↑", "↗", "←", "•", "→", "↙", "↓", "↘"]
                    Surface {
                        required property int index
                        required property string modelData
                        objectName: "imageAnchor_" + index
                        readonly property bool on: root.anchor === index
                        width: Theme.ctl(22); height: Theme.ctl(22)
                        radius: Theme.radiusSm
                        role: on ? "accent" : Theme.faceOf("button", anchorMouse.containsMouse)
                        borderRole: on ? "accent" : "border"; borderWidth: 1
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button; Accessible.name: Theme.imageAnchors[index]
                        Accessible.checkable: true; Accessible.checked: on
                        Accessible.onPressAction: root.picker.setOption("anchor", index)
                        Keys.onSpacePressed: root.picker.setOption("anchor", index)
                        Keys.onReturnPressed: root.picker.setOption("anchor", index)
                        InkText { anchors.centerIn: parent; text: parent.modelData
                                  ink: parent.on ? "textOnAccent" : "textDim"; font.pixelSize: Theme.fs(12) }
                        MouseArea { id: anchorMouse; anchors.fill: parent; hoverEnabled: true
                                    onClicked: root.picker.setOption("anchor", parent.index) }
                    }
                }
            }
        }
        Column {
            width: root.width - (root.sliced ? 0 : anchorBox.width + Theme.gap(8))
            spacing: Theme.gap(4)
            Item {
                width: parent.width; height: Theme.ctl(18)
                InkText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                          text: root.sliced ? "slices · px" : "zoom point"; ink: "textDim"; font.pixelSize: Theme.fs(11) }
                Surface {
                    anchors.right: parent.right
                    visible: !root.sliced
                    width: Theme.sp(34); height: parent.height
                    role: Theme.faceOf("button", autoMouse.containsMouse)
                    radius: Theme.radiusSm
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button; Accessible.name: "Reset zoom point"
                    Accessible.onPressAction: root.resetFocus()
                    Keys.onSpacePressed: root.resetFocus()
                    InkText { anchors.centerIn: parent; text: "auto"; ink: "textDim"; font.pixelSize: Theme.fs(10) }
                    MouseArea { id: autoMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.resetFocus() }
                }
            }
            Surface {
                id: preview
                objectName: "imagePlacementPreview"
                width: parent.width; height: Theme.ctl(72)
                role: "input"; borderRole: "border"; borderWidth: 1
                clip: true
                readonly property real imageLeft: (width - picture.paintedWidth) / 2
                readonly property real imageTop: (height - picture.paintedHeight) / 2
                readonly property var cutsX: root.cutPair(root.picker ? root.picker.optionOf("sliceLeft") : 0,
                    root.picker ? root.picker.optionOf("sliceRight") : 0, picture.sourceWidth)
                readonly property var cutsY: root.cutPair(root.picker ? root.picker.optionOf("sliceTop") : 0,
                    root.picker ? root.picker.optionOf("sliceBottom") : 0, picture.sourceHeight)
                Image {
                    id: picture
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    // Loaded the way StyledFill loads its pictures, which
                    // says why: an SVG is sync and set before its source.
                    readonly property string wanted: root.picker ? root.picker.stSrc : ""
                    onWantedChanged: request()
                    Component.onCompleted: request()
                    function request() {
                        source = ""
                        asynchronous = !/\.(svgz?|pdf)(\?|#|$)/i.test(wanted)
                        source = wanted
                    }
                    readonly property real sourceWidth: Math.round(implicitWidth)
                    readonly property real sourceHeight: Math.round(implicitHeight)
                }
                Item {
                    visible: !root.sliced && picture.status === Image.Ready
                    x: preview.imageLeft + root.focusX * picture.paintedWidth
                    y: preview.imageTop + root.focusY * picture.paintedHeight
                    Rectangle { x: -Theme.ctl(6); y: x; width: Theme.ctl(12); height: width; radius: width / 2
                                color: "transparent"; border.color: "black"; border.width: 1 }
                    Rectangle { x: -Theme.ctl(5); y: x; width: Theme.ctl(10); height: width; radius: width / 2
                                color: "transparent"; border.color: "white"; border.width: 2 }
                }
                Repeater {
                    model: root.sliced && picture.status === Image.Ready ? 4 : 0
                    Rectangle {
                        required property int index
                        readonly property bool vertical: index < 2
                        readonly property real fraction: vertical
                            ? (index === 0 ? preview.cutsX[0] : picture.sourceWidth - preview.cutsX[1]) / picture.sourceWidth
                            : (index === 2 ? preview.cutsY[0] : picture.sourceHeight - preview.cutsY[1]) / picture.sourceHeight
                        x: preview.imageLeft + (vertical ? fraction * picture.paintedWidth : 0)
                        y: preview.imageTop + (vertical ? 0 : fraction * picture.paintedHeight)
                        width: vertical ? Theme.ctl(2) : picture.paintedWidth
                        height: vertical ? picture.paintedHeight : Theme.ctl(2)
                        color: "white"; border.color: "#303030"; border.width: 0.5
                    }
                }
                MouseArea {
                    objectName: "imageFocusPick"
                    anchors.fill: parent
                    enabled: !root.sliced && picture.status === Image.Ready
                    function place(mouse) {
                        root.pick((mouse.x - preview.imageLeft) / Math.max(1, picture.paintedWidth),
                                  (mouse.y - preview.imageTop) / Math.max(1, picture.paintedHeight))
                    }
                    onPressed: mouse => place(mouse)
                    onPositionChanged: mouse => { if (pressed) place(mouse) }
                }
            }
        }
    }
    Grid {
        width: parent.width
        visible: root.sliced
        columns: 2; spacing: Theme.gap(6)
        Repeater {
            model: ["Left", "Right", "Top", "Bottom"]
            Item {
                required property string modelData
                readonly property string key: "slice" + modelData
                width: (root.width - Theme.gap(6)) / 2; height: Theme.ctl(26)
                InkText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                          text: parent.modelData.toLowerCase(); ink: "textDim"; font.pixelSize: Theme.fs(11) }
                Surface {
                    anchors.right: parent.right
                    width: parent.width - Theme.sp(45); height: parent.height
                    role: "input"; borderRole: input.activeFocus ? "borderStrong" : "border"; borderWidth: 1
                    radius: Theme.radiusSm
                    TextInput {
                        id: input
                        objectName: "imageCut_" + parent.parent.modelData
                        anchors.fill: parent; anchors.margins: Theme.gap(4)
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.text; selectionColor: Theme.accent; selectedTextColor: Theme.textOnAccent
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fs(11)
                        selectByMouse: true
                        validator: IntValidator { bottom: 0; top: 255 }
                        Accessible.name: parent.parent.modelData + " slice"
                        onTextEdited: if (acceptableInput && root.picker) root.picker.setOption(parent.parent.key, Number(text))
                        onEditingFinished: text = String(root.picker ? root.picker.optionOf(parent.parent.key) : 8)
                        Binding { target: input; property: "text"; when: !input.activeFocus
                                  value: String(root.picker ? root.picker.optionOf(input.parent.parent.key) : 8) }
                    }
                }
            }
        }
    }
}
