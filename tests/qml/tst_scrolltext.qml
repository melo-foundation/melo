import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// Headless verification of ScrollText: does hover actually start the marquee,
// both via the internal HoverHandler and via an external row MouseArea?
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml
Item {
    width: 400; height: 200

    // case 1: bare ScrollText (player-bar situation)
    ScrollText {
        id: bare
        x: 10; y: 10; width: 150
        text: "This is a very long track title that definitely overflows the box"
        color: "white"
        font.pixelSize: 13
    }

    // case 2: ScrollText under a hover-enabled row MouseArea (list situation)
    Rectangle {
        id: row
        x: 10; y: 60; width: 200; height: 40
        color: rowMa.containsMouse ? "#333333" : "#111111"
        ScrollText {
            id: covered
            x: 5; y: 12; width: 150
            text: "Another very long track title that definitely overflows the box"
            color: "white"
            font.pixelSize: 13
            hoverSource: rowMa
        }
        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true }
    }

    // case 3: the compact row's situation — an ink-bearing label laid out and
    // hidden while the list is in another layout
    ScrollText {
        id: unseen
        visible: false
        x: 10; y: 110; width: 150
        text: "A title in the layout that is not on screen"
        ink: "text"
        font.pixelSize: 13
    }
    ScrollText {
        id: seen
        x: 10; y: 150; width: 150
        text: "A title in the layout that is"
        ink: "text"
        font.pixelSize: 13
    }

    TestCase {
        name: "ScrollText"
        when: windowShown

        function test_a_overflow_math() {
            verify(bare.overflow > 1, "bare overflow: " + bare.overflow)
            verify(covered.overflow > 1, "covered overflow: " + covered.overflow)
        }

        function test_b_bare_hover_scrolls() {
            mouseMove(bare, 20, 5)
            wait(50)
            verify(bare.scrolling, "bare.scrolling after hover; hh path")
            wait(bare.ms * 0.2)   // past the 15% start pause
            verify(bare.scrollX < -1, "bare label moved: x=" + bare.scrollX)
            mouseMove(bare, 300, 150)   // move away (still inside root Item)
            wait(50)
            verify(!bare.scrolling, "bare stops after unhover")
            compare(bare.scrollX, 0)
        }

        function test_c_covered_hover_scrolls() {
            mouseMove(covered, 20, 5)
            wait(50)
            verify(rowMa.containsMouse, "row highlight works")
            verify(covered.extHover, "extHover sees cursor")
            verify(covered.scrolling, "covered.scrolling via hoverSource")
            wait(covered.ms * 0.2)
            verify(covered.scrollX < -1, "covered label moved: x=" + covered.scrollX)
            // cursor on the row but NOT on the text -> highlight yes, scroll no
            mouseMove(row, 180, 35)
            wait(50)
            verify(rowMa.containsMouse, "row still hovered")
            verify(!covered.scrolling, "text not hovered -> no scroll")
        }

        // Nothing is built for a label nobody can see, and one that comes
        // into view has its twin before the frame it appears in.
        function test_d_a_hidden_label_builds_no_twin() {
            Theme.held = true
            Theme.p.text = ({ colour: "#3060ff", source: "opal", params: ({ speed: 0 }) })
            Theme.pChanged()
            verify(seen.twin, "the ink asks for a twin")
            verify(seen.twinActive, "a label on screen has one")
            verify(unseen.twin, "the hidden label asks for one too")
            verify(!unseen.twinActive, "and does not build it")
            unseen.visible = true
            verify(unseen.twinActive, "showing it builds it, in the same turn")
            unseen.visible = false
            verify(!unseen.twinActive)
            // a label that will dissolve into view keeps its twin while hidden
            unseen.keepTwin = true
            verify(unseen.twinActive, "kept, so the words are there the frame it shows")
            unseen.keepTwin = false
            verify(!unseen.twinActive)
            delete Theme.p.text
            Theme.pChanged()
            Theme.held = false
        }
    }
}
