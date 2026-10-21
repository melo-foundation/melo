import QtQuick
import QtTest
import "../../src/qml/components"
import "../../src/qml/components/errorui.js" as ErrorUi

// One error look: Report… on the left, the other answers, the main one on the
// right, in the dialog and the bar alike; bars stack upward from above the
// player bar and never reach it.
Item {
    id: root
    width: 520; height: 600

    ErrorPanel {
        id: dialogSize
        blocking: true
        width: 400; height: implicitHeight; maxWidth: 400
        message: "This video is unavailable"
        namePrefix: "d_"
        messageName: "dialogText"
        actions: [{ id: "retry", label: "Retry" }, { id: "skip", label: "Skip" }, { id: "report", label: "Report…" }]
    }
    // an update notice: no alert glyph, Release notes left of Update
    ErrorPanel {
        id: updateBar
        y: 200
        width: implicitWidth; height: implicitHeight; maxWidth: 480
        message: "melo 0.5.0"
        alert: false
        namePrefix: "u_"
        actions: [{ id: "update", label: "Update" }, { id: "notes", label: "Release notes" }]
    }
    // a message that wraps to three lines in a bar as narrow as the mini player's
    readonly property string wrapping: "YouTube is blocking guest playback from your network. Use your browser's YouTube account."
    ErrorPanel {
        id: narrowBar
        y: 250
        width: 300; height: implicitHeight; maxWidth: 300
        message: root.wrapping
        messageName: "narrowText"
        actions: [{ id: "retry", label: "Try again" }, { id: "skip", label: "Skip" }]
    }
    // the test theme's words are light ink, so the page under them is dark
    Rectangle { x: 305; y: 245; width: 215; height: inline.height + 10; color: inline.face }
    InlineError {
        id: inline
        objectName: "inline"
        face: "#1a1a1a"
        x: 310; y: 250
        width: 200; height: implicitHeight
        message: root.wrapping
    }
    Rectangle { id: bar; anchors.bottom: parent.bottom; width: parent.width; height: 80 }
    ErrorBarStack {
        id: stack
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: bar.top
        anchors.bottomMargin: 8
        maxWidth: 480
        notices: [
            { key: "one", message: "The download failed.", actions: [{ id: "report", label: "Report…" }] },
            { key: "two", message: "Playback failed in a way a newer yt-dlp usually fixes.",
              actions: [{ id: "nightly", label: "Switch to Nightly" }, { id: "no", label: "Not now" }, { id: "report", label: "Report…" }],
              sticky: true },
        ]
    }
    SignalSpy { id: picks; target: stack; signalName: "triggered" }
    SignalSpy { id: gone; target: stack; signalName: "dismissed" }

    TestCase {
        name: "ErrorUi"
        when: windowShown

        function test_order_is_report_then_others_then_the_main_one() {
            const o = ErrorUi.ordered([{ id: "browser" }, { id: "retry" }, { id: "skip" }, { id: "report" }])
            compare(o.map((a) => a.id), ["report", "retry", "skip", "browser"])
            compare(ErrorUi.primaryOf([{ id: "report" }, { id: "ok" }]), "ok")
            compare(ErrorUi.ordered([{ id: "report" }]).map((a) => a.id), ["report"])
        }

        function test_dialog_buttons_left_to_right() {
            waitForRendering(dialogSize)
            const r = findChild(dialogSize, "d_report"), s = findChild(dialogSize, "d_skip"), t = findChild(dialogSize, "d_retry")
            const x = (i) => i.mapToItem(dialogSize, 0, 0).x
            verify(x(r) < x(s) && x(s) < x(t))
            verify(t.accent && !s.accent && !r.accent)
            verify(x(r) < dialogSize.width / 2, "Report… at the left edge")
        }

        function test_bars_stack_above_the_player_bar() {
            waitForRendering(stack)
            const one = findChild(stack, "notice_one"), two = findChild(stack, "notice_two")
            verify(one && two)
            const b1 = one.mapToItem(root, 0, one.height).y, b2 = two.mapToItem(root, 0, two.height).y
            verify(b1 <= two.mapToItem(root, 0, 0).y, "stacked, not overlapping")
            verify(b2 <= bar.y, "the stack ends above the player bar")
            const rep = findChild(stack, "notice_two_report"), main = findChild(stack, "notice_two_nightly")
            verify(rep.mapToItem(root, 0, 0).x < main.mapToItem(root, 0, 0).x)
        }

        function test_a_notice_goes_without_the_alert_glyph() {
            waitForRendering(updateBar)
            compare(updateBar.iconW, 0)
            verify(dialogSize.iconW > 0)
            const notes = findChild(updateBar, "u_notes"), upd = findChild(updateBar, "u_update")
            verify(notes.mapToItem(updateBar, 0, 0).x < upd.mapToItem(updateBar, 0, 0).x)
            verify(upd.accent && !notes.accent)
        }

        // rows of `img` with ink in columns [x0, x1) of `rect` (root coordinates, dpr 1)
        function inkRows(img, x0, x1, y0, y1) {
            const bg = img.pixel(Math.round(x0) - 2, Math.round(y0))
            const far = (c) => Math.abs(c.r - bg.r) + Math.abs(c.g - bg.g) + Math.abs(c.b - bg.b) > 0.45
            let top = -1, bot = -1
            for (let y = Math.round(y0); y < Math.round(y1); y++)
                for (let x = Math.round(x0); x < Math.round(x1); x++)
                    if (far(img.pixel(x, y))) { if (top < 0) top = y; bot = y; break }
            return (top + bot) / 2
        }

        // the glyph's ink centres on the first line's capital, in the bar, the dialog and a page
        function test_the_glyph_lines_up_with_the_first_line_data() {
            return [{ tag: "bar", host: narrowBar, text: "narrowText" },
                    { tag: "dialog", host: dialogSize, text: "dialogText" },
                    { tag: "inline", host: inline, text: "inlineText" }]
        }
        function test_the_glyph_lines_up_with_the_first_line(data) {
            waitForRendering(data.host)
            const img = grabImage(root)
            const glyph = findChild(data.host, "alertGlyph")
            const words = findChild(data.host, data.text)
            if (data.tag !== "dialog") verify(words.lineCount >= 2, "the message wraps")
            const g = glyph.mapToItem(root, 0, 0), t = words.mapToItem(root, 0, 0)
            const firstLine = words.contentHeight / words.lineCount
            const glyphMid = inkRows(img, g.x, g.x + glyph.width, g.y - 4, g.y + glyph.height + 4)
            // the "Y" that opens the message
            const capMid = inkRows(img, t.x, t.x + words.font.pixelSize * 0.55, t.y, t.y + firstLine)
            verify(Math.abs(glyphMid - capMid) <= 1, data.tag + ": glyph " + glyphMid + ", capital " + capMid)
        }

        function test_buttons_answer_and_a_click_dismisses_the_transient_one() {
            picks.clear(); gone.clear()
            mouseClick(findChild(stack, "notice_two_nightly"))
            compare([picks.signalArguments[0][0], picks.signalArguments[0][1]], ["two", "nightly"])
            const one = findChild(stack, "notice_one")
            mouseClick(one, 10, one.height / 2)
            compare(gone.count, 1)
            compare(gone.signalArguments[0][0], "one")
            const two = findChild(stack, "notice_two")
            mouseClick(two, 10, two.height / 2)
            compare(gone.count, 1)   // a sticky one stays
        }
    }
}
