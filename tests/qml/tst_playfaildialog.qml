import QtQuick
import QtTest
import "../../src/qml/components"

// The dialog a track that cannot be loaded shows: its buttons per cause, what
// each answers, and the one-row form in a host as short as the mini player.
Item {
    id: root
    width: 520; height: 420

    Item { id: tall; anchors.fill: parent
        PlayFailDialog { id: dlg; reason: "YouTube is refusing guest playback from this address." }
    }
    Item { id: short; width: 520; height: 64
        PlayFailDialog { id: mini; reason: "YouTube is refusing guest playback from this address." }
    }
    SignalSpy { id: answers; target: dlg; signalName: "answered" }
    SignalSpy { id: miniAnswers; target: mini; signalName: "answered" }

    TestCase {
        name: "PlayFailDialog"
        when: windowShown

        function init() {
            answers.clear(); miniAnswers.clear(); dlg.shown = false; mini.shown = false
            dlg.choices = []; dlg.busy = false
        }

        // the buttons that are showing, in the dialog's action order
        function buttons(d) {
            const out = []
            for (const a of d.actions) {
                const b = findChild(d, "playFail_" + a)
                if (b && b.visible) out.push({ action: a, label: b.label, accent: b.accent, item: b })
            }
            return out
        }

        function test_buttons_per_cause_data() {
            return [
                { tag: "guest wall", cause: "guestWall", labels: ["Use browser account", "Retry", "Skip"] },
                { tag: "browser wall", cause: "browserWall", labels: ["Update yt-dlp", "Retry", "Skip"] },
                { tag: "sign-in", cause: "signin", labels: ["Sign in again", "Skip"] },
                { tag: "network", cause: "network", labels: ["Retry", "Skip"] },
                { tag: "other", cause: "other", labels: ["Retry", "Skip"] },
            ]
        }
        function test_buttons_per_cause(data) {
            dlg.cause = data.cause; dlg.shown = true
            waitForRendering(dlg)
            verify(dlg.visible)
            verify(!dlg.compact)
            const bs = buttons(dlg)
            compare(bs.map(b => b.label), data.labels)
            compare(bs.map(b => b.accent), data.labels.map((l, i) => i === 0))
            compare(findChild(dlg, "playFailReason").text, dlg.reason)
        }

        function test_each_button_answers_its_action() {
            dlg.cause = "guestWall"; dlg.shown = true
            waitForRendering(dlg)
            const bs = buttons(dlg)
            for (const b of bs) mouseClick(b.item)
            compare(answers.count, 3)
            compare([0, 1, 2].map(i => answers.signalArguments[i][0]), ["browser", "retry", "skip"])
        }

        function test_several_signed_in_browsers_are_a_choice() {
            dlg.cause = "guestWall"; dlg.choices = ["firefox", "chrome"]; dlg.shown = true
            waitForRendering(dlg)
            const bs = buttons(dlg)
            compare(bs.map(b => b.label), ["Firefox", "Chrome", "Skip"])
            mouseClick(bs[1].item)
            compare(answers.signalArguments[0][0], "browser:chrome")
        }

        function test_one_browser_is_no_choice() {
            dlg.cause = "guestWall"; dlg.choices = ["chrome"]; dlg.shown = true
            waitForRendering(dlg)
            compare(buttons(dlg).map(b => b.label), ["Use browser account", "Retry", "Skip"])
        }

        function test_checking_takes_only_skip() {
            dlg.cause = "guestWall"; dlg.busy = true; dlg.shown = true
            waitForRendering(dlg)
            const bs = buttons(dlg)
            compare(bs[0].label, "Checking…")
            for (const b of bs) mouseClick(b.item)
            keyClick(Qt.Key_Return)
            compare(answers.count, 1)
            compare(answers.signalArguments[0][0], "skip")
        }

        function test_escape_dismisses_and_enter_takes_the_first() {
            dlg.cause = "browserWall"; dlg.shown = true
            waitForRendering(dlg)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Return)
            compare(answers.count, 2)
            compare(answers.signalArguments[0][0], "dismiss")
            compare(answers.signalArguments[1][0], "update")
        }

        function test_hidden_without_a_cause_or_when_another_window_has_it() {
            dlg.cause = ""; dlg.shown = true
            verify(!dlg.visible)
            dlg.cause = "other"; dlg.shown = false
            verify(!dlg.visible)
        }

        function test_one_row_in_the_mini_player() {
            mini.cause = "browserWall"; mini.shown = true
            waitForRendering(mini)
            verify(mini.compact)
            const bs = buttons(mini)
            compare(bs.map(b => b.label), ["Update yt-dlp", "Retry", "Skip"])
            for (const b of bs) {
                const p = b.item.mapToItem(short, 0, 0)
                verify(p.y >= 0 && p.y + b.item.height <= short.height, b.label + " inside the bar")
            }
            mouseClick(bs[2].item)
            compare(miniAnswers.signalArguments[0][0], "skip")
        }
    }
}
