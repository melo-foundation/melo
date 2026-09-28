import QtQuick

// When to tell the user that the theme's glass has no blur behind it. The
// dialog itself is the caller's: this decides when to ask for it.
//
// Due while the theme wants blur, blur is missing and the user has not turned
// the notice off. It must stay due for `delay` ms before it fires, so KWin
// reloading its effects (capability gone, back within a few hundred ms) shows
// nothing. It fires once per run, and again only after blur has come back
// and gone away since.
Item {
    id: notice
    visible: false

    property bool active: true       // the window is up and can show a dialog
    property bool wanted: false      // the theme asks for blur
    property bool available: true    // the compositor blurs
    property bool suppressed: false  // "Don't show again", as saved
    property bool busy: false        // the dialog is showing something else
    property int delay: 1000

    // set by dismiss(true), for the rest of the run: `suppressed` is read
    // from settings, which the caller may not re-read
    property bool off: false
    property bool shown: false
    readonly property bool due: active && wanted && !available && !suppressed && !off && !shown

    signal showRequested()
    signal dontShowAgain()

    // the dialog's answer
    function dismiss(forever) {
        if (!forever) return
        off = true
        dontShowAgain()
    }

    onAvailableChanged: if (available) shown = false
    onDueChanged: if (due) timer.restart(); else timer.stop()

    Timer {
        id: timer
        interval: notice.delay
        onTriggered: {
            if (!notice.due) return
            if (notice.busy) { restart(); return }
            notice.shown = true
            notice.showRequested()
        }
    }
}
