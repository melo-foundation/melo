import QtQuick

// a stand-in for melo's C++ type, so a test can load Main.qml
Item {
    property var spec
    property var active
    property var input
    property var slices
    property var box
    property var hasShape
    property var fieldSize
    property var generation
    property var edgeRing
    property var grabRing
    property var fieldBox
    property var fieldSlices
    property var cropFit
    signal shapeApplied()
    signal shapeChanged()
    function edgeNormalAt(x, y) { return undefined }
    function intrusion(edge, from, to) { return undefined }
    function distanceAt(x, y) { return undefined }
    function maskAt(x, y) { return undefined }
}
