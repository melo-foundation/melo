pragma Singleton
import QtQuick

// Full-text popup for truncated labels. Main.qml registers the overlay
// implementation (a floating card in the main window); callers just
// Tip.show(text, item) / Tip.hide(item).
QtObject {
    property var impl: null
    function show(text, item) { if (impl) impl.showFor(text, item) }
    function hide(item) { if (impl) impl.hideFor(item) }
}
