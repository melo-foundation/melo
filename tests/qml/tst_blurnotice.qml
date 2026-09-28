import QtQuick
import QtTest
import "../../src/qml/components"

// When melo says the theme's glass has no blur behind it, and what the
// dialog's two buttons and Escape answer.
Item {
    id: root
    width: 500; height: 400

    BlurNotice { id: bn; delay: 40; active: false }
    SignalSpy { id: shows; target: bn; signalName: "showRequested" }
    SignalSpy { id: saves; target: bn; signalName: "dontShowAgain" }

    PromptDialog { id: pd }

    TestCase {
        name: "BlurNotice"
        when: windowShown

        function init() {
            bn.active = false
            bn.wanted = true; bn.available = false
            bn.suppressed = false; bn.busy = false
            bn.off = false; bn.shown = false
            shows.clear(); saves.clear()
        }
        function cleanup() { if (pd.visible) pd.reject() }

        function test_shows_once_when_glass_theme_has_no_blur() {
            bn.active = true
            shows.wait(1000)
            compare(shows.count, 1)
            // switching to another glass theme in the same run asks nothing
            bn.wanted = false; bn.wanted = true
            wait(120)
            compare(shows.count, 1)
        }

        function test_nothing_for_theme_without_blur() {
            bn.wanted = false
            bn.active = true
            wait(120)
            compare(shows.count, 0)
        }

        function test_nothing_when_blur_is_there() {
            bn.available = true
            bn.active = true
            wait(120)
            compare(shows.count, 0)
        }

        function test_blur_back_within_delay_shows_nothing() {
            bn.available = true
            bn.active = true
            bn.available = false
            wait(10)
            bn.available = true
            wait(120)
            compare(shows.count, 0)
        }

        function test_blur_back_then_gone_shows_again() {
            bn.active = true
            shows.wait(1000)
            bn.available = true
            bn.available = false
            shows.wait(1000)
            compare(shows.count, 2)
        }

        function test_saved_dont_show_again_is_honoured() {
            bn.suppressed = true
            bn.active = true
            wait(120)
            compare(shows.count, 0)
        }

        function test_dont_show_again_saves_and_holds_for_the_run() {
            bn.active = true
            shows.wait(1000)
            bn.dismiss(true)
            compare(saves.count, 1)
            bn.available = true
            bn.available = false
            wait(120)
            compare(shows.count, 1)
        }

        function test_ok_saves_nothing() {
            bn.active = true
            shows.wait(1000)
            bn.dismiss(false)
            compare(saves.count, 0)
        }

        function test_waits_for_a_dialog_already_open() {
            bn.busy = true
            bn.active = true
            wait(120)
            compare(shows.count, 0)
            bn.busy = false
            shows.wait(1000)
            compare(shows.count, 1)
        }

        function test_dialog_buttons_answer() {
            let got = null
            const text = "Window blur support was not detected. This theme may be less legible."
            pd.noticeDialog(text, "OK", "Don't show again", (a) => got = a)
            verify(pd.visible)
            const alt = findChild(pd, "promptCancel")
            const ok = findChild(pd, "promptOk")
            compare(alt.label, "Don't show again")
            compare(ok.label, "OK")
            mouseClick(alt)
            compare(got, "alt")
            verify(!pd.visible)

            pd.noticeDialog(text, "OK", "Don't show again", (a) => got = a)
            mouseClick(findChild(pd, "promptOk"))
            compare(got, "ok")

            // Escape is not "Don't show again"
            pd.noticeDialog(text, "OK", "Don't show again", (a) => got = a)
            got = null
            keyClick(Qt.Key_Escape)
            compare(got, "ok")
            verify(!pd.visible)
        }

        function test_ask_dialog_keeps_its_cancel() {
            let got = null
            pd.askDialog("q", "Yes", "No", "", (ok) => got = ok)
            mouseClick(findChild(pd, "promptCancel"))
            compare(got, false)
        }
    }
}
