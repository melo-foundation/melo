import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_popupmodetoggle.qml
Item {
    width: 300; height: 60
    property var picks: []
    PopupModeToggle { id: t; video: false; onPicked: (v) => picks.push(v) }

    TestCase {
        name: "PopupModeToggle"
        when: windowShown

        function init() { t.video = false; picks = [] }

        function segs() {
            const out = []
            function walk(i) { for (const c of i.children) { if (c.objectName.startsWith("seg:")) out.push(c); walk(c) } }
            walk(t); return out
        }

        function test_two_segments_one_active() {
            const s = segs()
            compare(s.length, 2)
            compare(s[0].objectName, "seg:visualizer")
            compare(s[1].objectName, "seg:video")
            verify(s[0].active); verify(!s[1].active)
        }

        function test_clicking_video_reports_it_and_does_not_flip_itself() {
            const s = segs()
            mouseClick(s[1])
            compare(picks.length, 1); compare(picks[0], true)
            verify(!s[1].active)      // the owner flips `video` after saving it
            t.video = true
            verify(s[1].active); verify(!s[0].active)
            mouseClick(s[0])
            compare(picks[1], false)
        }
    }
}
