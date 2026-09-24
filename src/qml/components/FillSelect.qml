import QtQuick
import QtQuick.Window
import ".."

// The fill for one layer, in its own window: every kind (melo's and plugins')
// drawn live in that layer's colour and levers. Picking applies at once and the
// window stays open, so each kind shows on the real surface behind it.
Window {
    id: sel
    property var picker: null
    visible: false
    color: "transparent"
    title: "melo fill"
    flags: Qt.Window | Qt.FramelessWindowHint
    minimumWidth: Theme.sp(300)
    minimumHeight: Theme.ctl(180)

    // Only the filters the fill list can answer. A kind declares whether it
    // reads the shape and whether it takes a palette; nothing says which ones
    // "animate", because every one of them does above speed 0.
    property bool onlyShape: false
    property bool onlyPalette: false
    property bool onlyFilter: false
    // A filter needs something under it, and the bottom layer has nothing
    // under it inside the stack — so none are offered there.
    readonly property bool filtersApply: picker !== null && picker.layerAt > 0
    // ...and a gallery narrowed to filters would be EMPTY there, with the chip
    // that narrowed it hidden — so the chip lets go when the layer does.
    onFiltersApplyChanged: if (!filtersApply) onlyFilter = false
    readonly property var kinds: {
        const all = picker ? picker.sourceModes : []
        const out = []
        for (let i = 0; i < all.length; ++i) {
            const k = all[i]
            const isF = Theme.isFilter(k)
            if (isF && !filtersApply) continue
            if (onlyFilter && !isF) continue
            if (onlyShape && !Theme.fillShape(k)) continue
            if (onlyPalette && !Theme.fillPalette(k)) continue
            out.push(k)
        }
        return out
    }
    // what a filter's tile filters: the layer under the selected one, as it
    // is right now — the real thing, not a stand-in
    readonly property var under: filtersApply ? picker.layerEntries()[picker.layerAt - 1] : null

    function openBeside() {
        applyGlass()
        // beside the picker, not over it: the point is watching the picker
        // change while flipping through kinds
        if (picker && picker.visible) {
            width = Math.max(minimumWidth, Math.round(Theme.sp(460)))
            height = Math.max(minimumHeight, Math.round(titleBar.height + body.wanted + pad + padB))
            x = picker.x + picker.width + Theme.gap(8)
            y = picker.y
        }
        visible = true
        requestActivate()
    }
    function applyGlass() {
        if (typeof WindowCtl === "undefined") return
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(sel, Theme.glassBlur !== "off" && Theme.translucent("window"))
    }
    // the picker going away takes this with it: a fill selector with nothing
    // to select for is a window nobody can dismiss meaningfully
    Connections {
        target: sel.visible && sel.picker ? sel.picker : null
        function onVisibleChanged() { if (!sel.picker.visible) sel.visible = false }
    }

    // the body's edge: the tool-window inset, `pad` the vertical one for the height sums
    readonly property real pad: Theme.inset("tool", "top")
    readonly property real padB: Theme.inset("tool", "bottom")
    readonly property real gap: Theme.gap(6)
    readonly property bool compact: width < Theme.sp(420)
    readonly property real tileHeight: Theme.ctl(compact ? 18 : 26) + Theme.fs(12) + Theme.gap(2)

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.height
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Theme.windowRadius; bottomRightRadius: Theme.windowRadius
        visible: Theme.hasPage
    }
    Surface {
        anchors.fill: parent
        role: ""
        radius: Theme.windowRadius
        borderRole: "windowBorder"
        borderWidth: Theme.windowBorderWidth
        visible: Theme.windowBorder
        z: 1000
    }
    Surface {
        id: titleBar
        width: parent.width
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Theme.windowRadius
        topRightRadius: Theme.windowRadius
        MouseArea { anchors.fill: parent; onPressed: sel.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left; anchors.leftMargin: Theme.inset("title", "left")
            text: "Fill"
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightMedium }
        }
        Item {
            anchors.right: parent.right; anchors.rightMargin: Theme.inset("title", "right")
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            width: Theme.ctl(26); height: Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                ink: xMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: xMa.containsMouse; pressed: xMa.pressed
                frameWidth: Theme.iconBtn; frameHeight: Math.min(Theme.iconBtn, Theme.ctl(20) + Theme.inset("title", "top") + Theme.inset("title", "bottom")) }
            MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: sel.visible = false }
        }
    }

    Item {
        id: body
        objectName: "fillSelectBody"
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: titleBar.bottom; anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.inset("tool", "left"); anchors.rightMargin: Theme.inset("tool", "right")
        anchors.topMargin: sel.pad; anchors.bottomMargin: sel.padB

        Row {
            id: filters
            objectName: "fillFilters"
            width: parent.width
            spacing: Theme.gap(4)
            component Chip: Surface {
                property string label
                property bool on: false
                signal toggled()
                width: Theme.ctl(64); height: Theme.ctl(20)
                radius: Theme.radiusSm
                role: on ? "accent" : Theme.faceOf("segment", cMa.containsMouse)
                borderWidth: 1; borderRole: on ? "accent" : "border"
                Text {
                    anchors.centerIn: parent
                    text: parent.label
                    color: parent.on ? Theme.onFill(parent.color) : Theme.textDim
                    font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                }
                MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true; onClicked: parent.toggled() }
            }
            Chip { objectName: "fillFilter_shape"; label: "shape"; on: sel.onlyShape
                   onToggled: sel.onlyShape = !sel.onlyShape }
            Chip { objectName: "fillFilter_palette"; label: "palette"; on: sel.onlyPalette
                   onToggled: sel.onlyPalette = !sel.onlyPalette }
            Chip { objectName: "fillFilter_filter"; label: "filter"; on: sel.onlyFilter
                   visible: sel.filtersApply
                   onToggled: sel.onlyFilter = !sel.onlyFilter }
        }

        Grid {
            id: grid
            objectName: "fillGrid"
            anchors.top: filters.bottom
            anchors.topMargin: sel.gap
            width: parent.width
            columns: Math.max(4, Math.floor((width + Theme.gap(4))
                / (Math.max(Theme.ctl(sel.compact ? 42 : 48), Theme.fs(9) * (sel.compact ? 4.6 : 5.3)) + Theme.gap(4))))
            columnSpacing: Theme.gap(4); rowSpacing: Theme.gap(3)
            readonly property int rowCount: Math.ceil(sel.kinds.length / columns)
            readonly property real wantedHeight: rowCount * sel.tileHeight
                                               + Math.max(0, rowCount - 1) * Theme.gap(3)

            Repeater {
                model: sel.kinds
                Item {
                    id: tile
                    required property string modelData
                    readonly property string kind: modelData
                    objectName: "fillTile_" + kind
                    readonly property bool on: sel.picker && sel.picker.sourceMode === kind
                    width: (grid.width - (grid.columns - 1) * Theme.gap(4)) / grid.columns
                    height: sel.tileHeight
                    Checker { anchors.fill: parent; anchors.bottomMargin: Theme.fs(12) + Theme.gap(2) }
                    Item {
                        id: face
                        anchors.fill: parent; anchors.bottomMargin: Theme.fs(12) + Theme.gap(2)
                        Rectangle {
                            anchors.fill: parent
                            visible: tile.kind === "colour"
                            color: sel.picker ? sel.picker.colour1 : "transparent"
                        }
                        // adaptive has no look of its own: what it would do to a
                        // mid grey and to white, side by side
                        Row {
                            anchors.fill: parent
                            visible: tile.kind === "adaptive"
                            Rectangle { width: parent.width / 2; height: parent.height
                                        color: sel.picker ? Theme.adapt(Qt.rgba(0.5, 0.5, 0.5, 1),
                                            Qt.vector4d(sel.picker.adHue, sel.picker.adLum, sel.picker.adSat, 1)) : "transparent" }
                            Rectangle { width: parent.width / 2; height: parent.height
                                        color: sel.picker ? Theme.adapt(Qt.rgba(1, 1, 1, 1),
                                            Qt.vector4d(sel.picker.adHue, sel.picker.adLum, sel.picker.adSat, 1)) : "transparent" }
                        }
                        // A rectangle alone hides what a shape-aware style
                        // does. Show a rounded block AND a letter with a hole.
                        Item {
                            width: 0; height: 0; clip: true
                            Loader {
                                id: shapePreview
                                width: face.width; height: face.height
                                active: Theme.fillShape(tile.kind)
                                sourceComponent: Item {
                                    layer.enabled: true
                                    Rectangle {
                                        x: Theme.gap(2); y: Theme.gap(2)
                                        width: parent.width * 0.45 - Theme.gap(2)
                                        height: parent.height - Theme.gap(4)
                                        radius: height * 0.3; color: "white"
                                    }
                                    Text {
                                        x: parent.width * 0.48; width: parent.width * 0.52; height: parent.height
                                        text: "A"; color: "white"
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                                        font { pixelSize: Math.max(Theme.fs(12), face.height - Theme.gap(2)); family: Theme.fontFamily; bold: true }
                                    }
                                }
                            }
                        }
                        StyledFill {
                            anchors.fill: parent
                            visible: Theme.isFilter(tile.kind) && sel.under !== null
                            kind: "colour"
                            local: true
                            layers: sel.under !== null && Theme.isFilter(tile.kind)
                                    ? Theme.layersOf({ layers: [sel.under, ({ source: tile.kind })] }) : null
                        }
                        StyledFill {
                            anchors.fill: parent
                            visible: Theme.isStyled(tile.kind)
                            kind: tile.kind
                            mask: shapePreview.item
                            lineHeightPx: Theme.fillShape(tile.kind) ? face.height : 0
                            params: sel.picker ? sel.picker.liveParams : Theme.styledOf(null)
                            local: true
                            colourA: sel.picker ? sel.picker.colour1 : "#ffffff"
                            opacity: sel.picker ? sel.picker.colour1.a : 1
                        }
                    }
                    Rectangle {
                        anchors.fill: face
                        color: "transparent"
                        radius: Theme.radiusSm
                        border.color: tile.on ? Theme.accent : Theme.border
                        border.width: tile.on ? 2 : 1
                    }
                    InkText {
                        objectName: "fillLabel_" + tile.kind
                        anchors.top: face.bottom; anchors.topMargin: 1
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                        text: Theme.sourceName(tile.kind)
                        ink: tile.on ? "text" : "textDim"
                        font { pixelSize: Theme.fs(9); family: Theme.fontFamily }
                    }
                    MouseArea {
                        anchors.fill: parent
                        // applied at once, and this stays open: the point of a
                        // gallery is comparing, which means seeing each one on
                        // the surface it is actually for
                        onClicked: if (sel.picker) { sel.picker.sourceMode = tile.kind; sel.picker.livePreview() }
                    }
                }
            }
        }
        // what the grid needs, so the window can be sized to it
        readonly property real wanted: filters.height + sel.gap + grid.wantedHeight
    }
    onVisibleChanged: if (visible) fitHeight()
    function fitHeight() {
        height = Math.max(minimumHeight, Math.round(titleBar.height + body.wanted + sel.pad + padB))
    }
    Connections {
        target: sel.visible ? body : null
        function onWantedChanged() { sel.fitHeight() }
    }

    Shortcut { sequence: "Escape"; enabled: sel.visible; onActivated: sel.visible = false }
}
