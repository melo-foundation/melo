import QtQuick
import QtQuick.Window
import ".."

// Holds a picture drawn over its window's ground (the video). Readers of that
// ground sample it with this in it (GroundPictures), read from this item's layer,
// which is on while the ground is a layer. It must not hold a reader of the ground.
Item {
    id: gp
    readonly property Item ground: Theme.groundOf(gp.Window.window)
    // Registered on visibility alone: the ground's layer follows its readers, and a
    // reader's source follows the register, so tying the two would be a binding loop.
    readonly property bool shown: visible && opacity > 0.01 && width > 0 && height > 0
    layer.enabled: shown && ground !== null && ground.layer.enabled
    onShownChanged: shown ? Theme.addGroundPicture(gp) : Theme.dropGroundPicture(gp)
    Component.onCompleted: if (shown) Theme.addGroundPicture(gp)
    Component.onDestruction: Theme.dropGroundPicture(gp)
}
