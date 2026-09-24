import QtQuick
import Melo 1.0

// The window's shape (WindowShapeItem): what lies outside it is cleared over
// everything the window draws, and clicks pass through there. Loaded by the
// windows that cannot import Melo themselves, so a test harness without the
// module never builds one.
WindowShape {
    anchors.fill: parent
}
