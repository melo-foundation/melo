import QtQuick
import "../barstyles"
import "../.."

// One button: melo's own, or a plugin's.
BarGroup {
    required property var host
    bar: host.bar
    explicitIds: [host.doc.id]
    size: Theme.ctl(host.doc.size || 22)
}
