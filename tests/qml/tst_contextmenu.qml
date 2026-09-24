import QtQuick
import QtTest
import "../../src/qml/components"

// Right-click stack regression test: focused TextInput + the z:940
// focus-clear overlay + a row MouseArea + the real ContextMenu component.
// Guards the visibility-deadlock bug (layer bound to child's read-back
// visibility could never open).
Item {
    id: root
    width: 400; height: 300

    property bool actFired: false
    property point lastOpen: Qt.point(-1, -1)
    property int lastRow: 0

    TextInput { id: input; x: 10; y: 10; width: 100; height: 20; color: "white" }

    Rectangle {
        id: row
        x: 10; y: 60; width: 300; height: 40; color: "#222222"
        MouseArea {
            id: rowMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (m) => {
                if (m.button === Qt.RightButton) {
                    const p = rowMa.mapToItem(null, m.x, m.y)
                    root.lastOpen = Qt.point(p.x, p.y)
                    root.lastRow = 1
                    cm.open(p.x, p.y, [
                        { label: "Play", act: () => root.actFired = true },
                        { label: "Other", act: () => {} },
                    ])
                }
            }
        }
    }

    Rectangle {
        id: row2
        x: 10; y: 110; width: 300; height: 40; color: "#333333"
        MouseArea {
            id: row2Ma
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (m) => {
                if (m.button === Qt.RightButton) {
                    const p = row2Ma.mapToItem(null, m.x, m.y)
                    root.lastOpen = Qt.point(p.x, p.y)
                    root.lastRow = 2
                    cm.open(p.x, p.y, [
                        { label: "Queue", act: () => {} },
                    ])
                }
            }
        }
    }

    // the focus-clear overlay from Main.qml, verbatim behavior
    MouseArea {
        anchors.fill: parent
        z: 940
        enabled: input.activeFocus
        acceptedButtons: Qt.AllButtons
        onPressed: (m) => {
            if (!(m.x >= input.x && m.x <= input.x + input.width
                  && m.y >= input.y && m.y <= input.y + input.height))
                input.focus = false
            m.accepted = false
        }
    }

    ContextMenu { id: cm }

    TestCase {
        name: "RightClickMenu"
        when: windowShown

        function test_a_rightclick_no_focus() {
            mouseClick(row, 20, 20, Qt.RightButton)
            wait(30)
            verify(root.lastOpen.x > 0, "row handler ran: " + root.lastOpen)
            verify(cm.visible, "menu opened (no focus in play)")
            // the menu is a separate popup window; click the first item
            // (Play) directly on the popup's box: margins 4 + row 0 mid (~14)
            mouseClick(cm.menuItem, cm.menuItem.width / 2, 4 + 14, Qt.LeftButton)
            wait(30)
            verify(root.actFired, "action fired")
            verify(!cm.visible, "menu closed after action")
        }

        function test_b_rightclick_while_input_focused() {
            root.actFired = false
            // test A showed the popup window; make sure the host window is
            // active again so the input can take focus (offscreen multi-window)
            if (root.Window.window) root.Window.window.requestActivate()
            wait(30)
            mouseClick(input, 5, 5, Qt.LeftButton)
            input.forceActiveFocus()
            wait(30)
            verify(input.activeFocus, "input focused -> overlay enabled")
            mouseClick(row, 20, 20, Qt.RightButton)
            wait(30)
            verify(!input.activeFocus, "overlay cleared focus")
            verify(cm.visible, "menu opened despite overlay")
        }

        // menu open on row 1 -> ONE right-click on row 2 must reopen it
        // there (the menuLayer fall-through contract)
        function test_c_reopen_on_other_row() {
            cm.close()
            wait(30)
            mouseClick(row, 20, 20, Qt.RightButton)
            wait(30)
            verify(cm.visible, "menu open on row 1")
            compare(root.lastRow, 1)
            mouseClick(row2, 30, 20, Qt.RightButton)
            wait(50)
            verify(cm.visible, "menu reopened by a single right-click on row 2")
            compare(root.lastRow, 2)
        }
    }
}
