import QtQuick
import ".."

// View tabs: Home, Library, and the conditional Search, Now playing and Visualizer.
Rectangle {
    id: tabBar
    // As tall as its tabs plus the insets above and below, so each inset adds
    // its own space.
    readonly property real tabH: Theme.viewTabs === "underline" ? 30
                               : Theme.viewTabs === "button" ? Theme.btnH : Theme.tabHeight
    // Plus the segment track, drawn a pad outside the tabs on every side; a
    // bar sized to the tabs alone lets it hang past the header, where the page
    // draws over its bottom edge.
    readonly property real trackPad: Theme.viewTabs === "segment" ? segTrack.pad : 0
    height: tabH + 2 * trackPad + Theme.inset("tabs", "top") + Theme.inset("tabs", "bottom")
    color: "transparent"
    // as wide as its tabs, for a header that puts it beside the search
    implicitWidth: tabRow.width + 2 * trackPad + Theme.inset("tabs", "left") + Theme.inset("tabs", "right")

    // What an adaptive chrome reads. Set by Main to the background layer:
    // that is the thing actually behind the header, and the shader cannot
    // sample the framebuffer the way a hardware blend does.
    property Item backdrop: null
    // its own chrome, unless it sits inside a row that is the chrome already
    property bool ground: true

    Surface {
        anchors.fill: parent
        z: -1
        visible: tabBar.ground
        role: "chrome"
        backdrop: tabBar.backdrop
    }

    property bool hasSearchResults: false

    SegmentTrack { id: segTrack; strip: tabRow; style: Theme.viewTabs }
    Row {
        id: tabRow
        anchors.top: parent.top
        anchors.topMargin: Theme.inset("tabs", "top") + tabBar.trackPad
        height: tabBar.tabH
        anchors.left: parent.left
        anchors.leftMargin: Theme.inset("tabs", "left") + tabBar.trackPad
        spacing: Theme.viewTabs === "segment" ? 0 : Theme.gap(Theme.tabGap)

        component Tab: SelectTab {
            id: tab
            property int view: -1
            property bool available: true
            visible: available
            style: Theme.viewTabs
            width: implicitWidth
            height: tabBar.tabH
            anchors.verticalCenter: parent.verticalCenter
            active: PlayerState.view === view
            hover: tabMa.containsMouse; pressed: tabMa.pressed
            fontSize: 12

            // Keyboard and screen-reader access.
            activeFocusOnTab: available
            Accessible.role: Accessible.PageTab
            Accessible.name: tab.label
            Accessible.checkable: true
            Accessible.checked: PlayerState.view === tab.view
            Accessible.onPressAction: PlayerState.view = tab.view
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Space || e.key === Qt.Key_Return
                    || e.key === Qt.Key_Enter) {
                    PlayerState.view = tab.view
                    e.accepted = true
                }
            }
            // The focus ring, so keyboard focus is visible.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: parent.radius + 2
                color: "transparent"
                border.color: Theme.accent
                border.width: 2
                visible: tab.activeFocus
            }
            MouseArea { id: tabMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: PlayerState.view = parent.view }
        }

        Tab { label: "Home"; view: 0 }
        Tab { label: "Library"; view: 1 }
        Tab { label: "Search"; view: 2; available: tabBar.hasSearchResults }
        Tab { label: "Now playing"; view: 5; available: PlayerState.hasTrack }
        Tab { label: "Visualizer"; view: 4; available: PlayerState.hasTrack }
    }
}
