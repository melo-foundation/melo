import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// `titleButtons` puts the title bar's window buttons on a framed face; `bare`
// (default) is the icon alone. The icon does not move between the two.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_iconbuttons.qml
Item {
    width: 600; height: 120
    TitleBar { id: title; width: 600 }

    TestCase {
        name: "IconButtons"
        when: windowShown
        function cleanup() { delete Theme.ts.titleButtons; Theme.tsChanged(); wait(20) }
        function set(v) { Theme.ts.titleButtons = v; Theme.tsChanged(); wait(20) }

        function buttons() {   // every IconButton in the title bar, in order
            const out = []
            function walk(it) {
                for (const c of it.children) {
                    if (c.objectName === "titleButton") out.push(c)
                    else walk(c)
                }
            }
            walk(title)
            return out
        }
        function faceOf(b) {
            for (const c of b.children) if (c.objectName === "iconFace") return c
            return null
        }
        function glyphOf(b) {
            for (const c of b.children) if (c.objectName === "iconGlyph") return c
            return null
        }
        function centreOf(b) {
            const g = glyphOf(b)
            return g.mapToItem(title, g.width / 2, g.height / 2)
        }

        // A held button sinks: the glyph moves a pixel down and right while
        // the mouse is down and comes back when it is let go.
        function test_sink_moves_the_glyph_while_it_is_held() {
            const b = buttons()[0]
            const rest = centreOf(b)
            Theme.ts.buttonPress = "sink"; Theme.tsChanged(); wait(20)
            compare(Math.round(centreOf(b).x), Math.round(rest.x), "nothing moves until it is pressed")
            mousePress(b, b.width / 2, b.height / 2)
            wait(20)
            const held = centreOf(b)
            compare(Math.round(held.x - rest.x), 1)
            compare(Math.round(held.y - rest.y), 1)
            mouseRelease(b, b.width / 2, b.height / 2)
            wait(20)
            const back = centreOf(b)
            compare(Math.round(back.x), Math.round(rest.x))
            compare(Math.round(back.y), Math.round(rest.y))
            delete Theme.ts.buttonPress; Theme.tsChanged(); wait(20)
        }

        // A gap of nought is nought: two framed faces touch. The button's
        // box is its face when it has one, so nothing but buttonGap separates
        // them.
        function test_button_gap_is_the_whole_gap() {
            Theme.ts.titleButtons = "button"; Theme.ts.buttonGap = 0; Theme.tsChanged(); wait(20)
            const bs = buttons()
            const a = faceOf(bs[bs.length - 2]), b = faceOf(bs[bs.length - 1])
            const ar = a.mapToItem(null, a.width, 0), bl = b.mapToItem(null, 0, 0)
            compare(Math.round(bl.x - ar.x), 0, "the faces touch")
            Theme.ts.buttonGap = 6; Theme.tsChanged(); wait(20)
            const ar2 = a.mapToItem(null, a.width, 0), bl2 = b.mapToItem(null, 0, 0)
            compare(Math.round(bl2.x - ar2.x), Theme.gap(6))
            delete Theme.ts.buttonGap; delete Theme.ts.titleButtons; Theme.tsChanged(); wait(20)
        }

        function test_bare_draws_no_face() {
            const bs = buttons()
            verify(bs.length >= 6)   // search settings pin minimize maximize close
            for (const b of bs) {
                compare(b.framed, false)
                compare(faceOf(b).visible, false)
                compare(b.width, b.size)   // the icon's own size, as it was
            }
        }

        function test_button_gives_every_icon_a_face_and_moves_none() {
            const bs = buttons()
            const before = bs.map(centreOf)
            set("button")
            for (let i = 0; i < bs.length; ++i) {
                const b = bs[i]
                compare(b.framed, true)
                compare(faceOf(b).visible, true)
                compare(b.width, b.frameWidth)
                compare(b.height, b.frameHeight)
                // the bar is 24 high and the face must fit in it
                verify(b.height <= title.height)
                const now = centreOf(b)
                compare(Math.round(now.x), Math.round(before[i].x))
                compare(Math.round(now.y), Math.round(before[i].y))
            }
            // and back
            set("bare")
            for (let i = 0; i < bs.length; ++i) {
                compare(faceOf(bs[i]).visible, false)
                const now = centreOf(bs[i])
                compare(Math.round(now.x), Math.round(before[i].x))
                compare(Math.round(now.y), Math.round(before[i].y))
            }
        }
    }
}
