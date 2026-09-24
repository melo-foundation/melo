import QtQuick

// Room, and nothing else. A spacer IS its width — which is why the renderer
// keys one on its document where every other kind is keyed on its kind.
Item {
    required property var host
    implicitWidth: host.doc.w || 0
    // Nothing to measure. A row is as tall as its tallest cell up to the
    // height it states, and a spacer holds nothing — a height here would make
    // a row of spacers as tall as an empty box instead of as tall as it says.
    implicitHeight: 0
}
