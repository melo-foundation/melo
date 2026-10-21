import QtQuick
import QtTest
import "../../src/qml/components"
import "../../src/qml/components/report.js" as Report
import "../../src/qml/components/playfail.js" as PlayFail

// The dialog a track that cannot be loaded shows: its buttons per cause, what
// each answers, and the one-row form in a host as short as the mini player.
Item {
    id: root
    width: 520; height: 420
    readonly property string browserWall: "YouTube is blocking playback from your network, even with your browser's account. Use yt-dlp nightly."

    Item { id: tall; anchors.fill: parent
        PlayFailDialog { id: dlg; reason: "YouTube is blocking guest playback from your network. Use your browser's YouTube account." }
    }
    Item { id: short; width: 520; height: 64
        PlayFailDialog { id: mini; reason: "YouTube is blocking guest playback from your network. Use your browser's YouTube account." }
    }
    SignalSpy { id: answers; target: dlg; signalName: "answered" }
    SignalSpy { id: miniAnswers; target: mini; signalName: "answered" }

    TestCase {
        name: "PlayFailDialog"
        when: windowShown

        function init() {
            answers.clear(); miniAnswers.clear(); dlg.shown = false; mini.shown = false
            dlg.choices = []; dlg.busy = false; dlg.stale = false; dlg.nightly = false
            dlg.reason = "YouTube is blocking guest playback from your network. Use your browser's YouTube account."
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

        // the words and the buttons per cause; Report… only where the cause is unknown
        function test_buttons_per_cause_data() {
            const browser = root.browserWall
            const onNightly = "YouTube is blocking playback from your network, even with your browser's account."
            const signedOut = "YouTube is blocking playback from your network, and your browser isn't signed in to YouTube. Sign in there, then try again."
            return [
                { tag: "guest wall", cause: "guestWall", reason: "YouTube is blocking guest playback from your network. Use your browser's YouTube account.", text: "YouTube is blocking guest playback from your network. Use your browser's YouTube account.",
                  labels: ["Use browser account", "Try again", "Skip"] },
                { tag: "browser wall", cause: "browserWall", reason: browser, text: browser,
                  labels: ["Use yt-dlp nightly", "Try again", "Skip"] },
                { tag: "browser wall on nightly", cause: "browserWall", reason: onNightly, text: onNightly,
                  labels: ["Try again", "Skip"] },
                { tag: "browser signed out", cause: "browserWall", reason: signedOut, text: signedOut,
                  labels: ["Try again", "Skip"] },
                { tag: "dropped", cause: "dropped", reason: "There was a problem with playback.",
                  text: "The connection to YouTube dropped. Try again.", labels: ["Try again", "Skip"] },
                { tag: "network", cause: "network", reason: "timeout",
                  text: "YouTube didn't answer. Check your connection and try again.", labels: ["Try again", "Skip"] },
                { tag: "unavailable", cause: "other", reason: "Video unavailable. This video is private",
                  text: "YouTube says this video is unavailable.",
                  labels: ["Skip", "Try again"] },
                { tag: "no yt-dlp", cause: "other", reason: "yt-dlp could not be downloaded; check the connection and try again",
                  text: "yt-dlp didn't download. Check your connection and try again.",
                  labels: ["Try again", "Skip"] },
                { tag: "offline", cause: "other", reason: "getaddrinfo ENOTFOUND www.youtube.com",
                  text: "YouTube didn't answer. Check your connection and try again.", labels: ["Try again", "Skip"] },
                { tag: "server error", cause: "other", reason: "ERROR: Unable to download webpage: HTTP Error 503: Service Unavailable",
                  text: "YouTube had a problem. Try again.", labels: ["Try again", "Skip"] },
                { tag: "unknown", cause: "other", reason: "Unexpected token < in JSON at position 0",
                  text: "This track didn't load.", labels: ["Try again", "Skip", "Report…"] },
            ]
        }
        function test_buttons_per_cause(data) {
            dlg.cause = data.cause; dlg.reason = data.reason; dlg.shown = true
            waitForRendering(dlg)
            verify(dlg.visible)
            verify(!dlg.compact)
            const bs = buttons(dlg)
            compare(bs.map(b => b.label), data.labels)
            compare(bs.map(b => b.accent), data.labels.map((l, i) => i === 0))
            compare(findChild(dlg, "playFailReason").text, data.text)
        }

        function test_report_only_for_an_unknown_cause() {
            for (const c of [["guestWall", "x"], ["browserWall", "x"], ["dropped", ""], ["network", ""],
                             ["other", "Video unavailable"], ["other", "timed out"],
                             ["other", "yt-dlp could not be downloaded"]])
                verify(PlayFail.actionsFor(c[0], [], c[1], false).indexOf("report") < 0, c.join(" "))
            verify(PlayFail.actionsFor("other", [], "something new", false).indexOf("report") >= 0)
        }

        function test_a_stale_ytdlp_offers_the_update() {
            dlg.cause = "other"; dlg.reason = "Requested format is not available"; dlg.stale = true; dlg.shown = true
            waitForRendering(dlg)
            compare(buttons(dlg).map(b => b.label), ["Use yt-dlp nightly", "Try again", "Skip"])
            compare(findChild(dlg, "playFailReason").text, "yt-dlp is out of date.")
        }

        function test_on_nightly_there_is_no_switch_to_offer() {
            dlg.nightly = true
            dlg.cause = "other"; dlg.reason = "Requested format is not available"; dlg.stale = true; dlg.shown = true
            waitForRendering(dlg)
            compare(buttons(dlg).map(b => b.label), ["Try again", "Skip"])
            dlg.cause = "browserWall"; dlg.reason = root.browserWall
            waitForRendering(dlg)
            compare(buttons(dlg).map(b => b.label), ["Try again", "Skip"])
            dlg.nightly = false
        }

        function test_each_button_answers_its_action() {
            dlg.cause = "guestWall"; dlg.shown = true
            waitForRendering(dlg)
            const bs = buttons(dlg)
            for (const b of bs) mouseClick(b.item)
            compare(answers.count, 3)
            compare([0, 1, 2].map(i => answers.signalArguments[i][0]), ["browser", "retry", "skip"])
        }

        function test_report_answers_report() {
            dlg.cause = "other"; dlg.reason = "something new"; dlg.shown = true
            waitForRendering(dlg)
            mouseClick(buttons(dlg)[2].item)
            compare(answers.signalArguments[0][0], "report")
        }

        function test_report_url_names_only_the_cause() {
            compare(Report.issueUrl("playback", "network"),
                    "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml"
                    + "&title=Playback%20problem%20(network)")
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
            compare(buttons(dlg).map(b => b.label), ["Use browser account", "Try again", "Skip"])
        }

        function test_checking_takes_only_skip_and_report() {
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
            dlg.cause = "browserWall"; dlg.reason = root.browserWall; dlg.shown = true
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
            mini.cause = "browserWall"; mini.reason = root.browserWall; mini.shown = true
            waitForRendering(mini)
            verify(mini.compact)
            const bs = buttons(mini)
            compare(bs.map(b => b.label), ["Use yt-dlp nightly", "Try again", "Skip"])
            for (const b of bs) {
                const p = b.item.mapToItem(short, 0, 0)
                verify(p.y >= 0 && p.y + b.item.height <= short.height, b.label + " inside the bar")
            }
            mouseClick(bs[2].item)
            compare(miniAnswers.signalArguments[0][0], "skip")
        }
    }
}
