import QtQuick

// What "transparent" looks like: a checkerboard. A light/dark split reads as
// part of the colour ramp rather than as the surface behind it; with a dark
// colour picked, the strip looks like white fading to black and says nothing
// about alpha.
Item {
    id: chk
    property int cell: 6
    readonly property int cols: Math.max(1, Math.ceil(width / cell))
    readonly property int rows: Math.max(1, Math.ceil(height / cell))
    clip: true
    Repeater {
        model: chk.cols * chk.rows
        Rectangle {
            required property int index
            width: chk.cell; height: chk.cell
            x: (index % chk.cols) * chk.cell
            y: Math.floor(index / chk.cols) * chk.cell
            color: ((index % chk.cols) + Math.floor(index / chk.cols)) % 2 === 0
                   ? "#ffffff" : "#bfbfbf"
        }
    }
}
