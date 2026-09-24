import QtQuick
import ".."

// A palette entry as a chip: the colour, or the fill it names drawn live,
// or what adaptive would do to grey and to white.
Item {
    id: chip
    property var entry
    property color fallback: "#000000"
    // A filter layer alone is nothing to look at: it changes what is under it.
    // A chip for one draws it over `under` — the layer beneath it, where the
    // caller has one — or over a plain grey ramp, which shows what the filter
    // does to something without pretending to be anything.
    property var under: null
    readonly property var sample: ({ colour: "#808080", source: "gradient",
                                     params: ({ speed: 0, scale: 1, angle: 0,
                                                colours: ["#303030", "#d0d0d0"] }) })
    readonly property bool filterAlone: Theme.isFilter(src) && Theme.layersOf(entry).length === 1
    property real radius: Theme.radiusSm
    readonly property string src: Theme.sourceOf(entry)
    readonly property color colour: Theme.colorOf(entry, fallback)

    Rectangle {
        anchors.fill: parent
        radius: chip.radius
        color: chip.colour
        visible: chip.src === "colour" && !Theme.layered(chip.entry)
    }
    Row {
        anchors.fill: parent
        visible: chip.src === "adaptive"
        Rectangle { width: parent.width / 2; height: parent.height
                    color: Theme.adapt(Qt.rgba(0.5, 0.5, 0.5, 1), Theme.adaptiveOf(chip.entry)) }
        Rectangle { width: parent.width / 2; height: parent.height
                    color: Theme.adapt(Qt.rgba(1, 1, 1, 1), Theme.adaptiveOf(chip.entry)) }
    }
    StyledFill {
        anchors.fill: parent
        visible: Theme.layered(chip.entry)
        kind: chip.src
        params: Theme.styledOf(chip.entry)
        colourA: chip.colour
        layers: chip.filterAlone
                ? Theme.layersOf({ layers: [chip.under !== null ? chip.under : chip.sample, chip.entry] })
                : Theme.layersOf(chip.entry)
        local: true
    }
    Rectangle {
        anchors.fill: parent
        radius: chip.radius
        color: "transparent"
        border.color: Theme.border
    }
}
