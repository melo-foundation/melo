import QtQuick

// A press anywhere in the host window closes the popup: melo's dropdowns are
// separate windows, and a press in melo's window often leaves their activation
// alone. It covers the popup's own field too, so a second click on the field
// closes the menu rather than closing and reopening it.
Item {
    id: scrim
    property var host: null   // the window the popup was opened from
    property bool active: false
    signal dismissed()

    parent: host && host.contentItem ? host.contentItem : null
    anchors.fill: parent ? parent : undefined
    z: 1000000
    visible: active && parent !== null

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: scrim.dismissed()
    }
}
