import QtQuick

// a stand-in for melo's C++ type, so a test can load Main.qml
Item {
    property var running
    property var frozen
    property var hasFrame
    property var fit
    property var fillMix
    property var contentRect
    function snapshot(name) { return undefined }
}
