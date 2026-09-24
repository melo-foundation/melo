pragma Singleton
import QtQuick
import "accounts.js" as Accounts

// The accounts, held once, so the title-bar menu, the wizard's dropdown and
// the settings window's Account choice change together.
// Re-read on a switch (the sidecar dropped its cookies), when an account menu
// opens, and when melo returns to the front, usually after a browser sign-in or
// out; every browser is re-read, since the menus list them all.
QtObject {
    id: store

    property var profiles: []
    property var browsers: []
    // cookies/status answers, keyed Accounts.statusKey(kind, id)
    property var status: ({})
    // Re-reads in flight. A browser re-read decrypts its store (a second or
    // two) and the stale answer shows until it lands; one past 300ms shows as
    // checking, so a quick one does not flicker the row.
    property var started: ({})    // key -> when its fresh read began
    property var checking: ({})   // keys shown as checking
    function settle(key) {
        if (!(key in store.started)) return
        const s = Object.assign({}, store.started); delete s[key]; store.started = s
        if (key in store.checking) { const c = Object.assign({}, store.checking); delete c[key]; store.checking = c }
    }
    property Timer slowReads: Timer {
        interval: 100; repeat: true
        running: Object.keys(store.started).length > 0
        onTriggered: {
            const now = Date.now(), c = {}
            for (const k in store.started) if (now - store.started[k] >= 300) c[k] = true
            if (JSON.stringify(c) !== JSON.stringify(store.checking)) store.checking = c
        }
    }

    // The active guest profile is always listed: the fetched list lags a
    // switch made elsewhere by a round trip, and the sidecar makes a guest
    // profile on first use, so the one in use exists.
    readonly property var shownProfiles:
        Settings.cookieSource === "guest" && Settings.cookieProfile.length
                && store.profiles.indexOf(Settings.cookieProfile) < 0
            ? store.profiles.concat([Settings.cookieProfile]) : store.profiles

    readonly property var entries: Accounts.entries({
        profiles: store.shownProfiles, browsers: store.browsers,
        cookieSource: Settings.cookieSource, cookieProfile: Settings.cookieProfile,
        browser: Settings.browser, status: store.status, checking: store.checking,
    })

    function ready() { return typeof sidecar !== "undefined" && sidecar && sidecar.ready }

    function ask(kind, id, fresh) {
        if (!ready()) return
        const key = Accounts.statusKey(kind, id)
        if (fresh && kind === "browser") {
            const s = Object.assign({}, store.started); s[key] = Date.now(); store.started = s
        }
        Accounts.askStatus(sidecar, kind, id, (k, st) => {
            const next = Object.assign({}, store.status)
            next[k] = st
            store.status = next
            store.settle(k)
        }, fresh, (k) => store.settle(k))
    }
    function askActive(fresh) {
        if (Settings.cookieSource === "browser") ask("browser", Settings.browser, fresh)
        else if (Settings.cookieSource === "guest") ask("guest", Settings.cookieProfile, fresh)
    }

    // the lists, then every identity on them; `fresh` re-reads each browser
    function refresh(fresh) {
        if (!ready()) return
        sidecar.rpc("cookies/profiles", {}, (r) => {
            const list = r.ok && r.result ? r.result.profiles : null
            store.profiles = (list && list.length) ? list : []
            for (const p of store.profiles) store.ask("guest", p, false)
        })
        sidecar.rpc("cookies/browsers", {}, (r) => {
            store.browsers = r.ok && r.result && r.result.browsers ? r.result.browsers : []
            for (const b of store.browsers) store.ask("browser", b, fresh)
        })
    }

    // Melo coming to the front from any of its windows, including the wizard
    // and the settings window. At most every 5 seconds: each read decrypts a
    // browser's store. And once more a little later, for a browser that had
    // not saved its cookies yet when melo came back.
    property double lastFront: 0
    function cameToFront() {
        if (Date.now() - lastFront < 5000) return
        lastFront = Date.now()
        refresh(true)
        lateCheck.restart()
    }
    property Timer lateCheck: Timer { interval: 12000; onTriggered: store.refresh(true) }
    property Connections appFront: Connections {
        target: Qt.application
        function onStateChanged() { if (Qt.application.state === Qt.ApplicationActive) store.cameToFront() }
    }

    readonly property string identity:
        Settings.cookieSource + "\u0000" + Settings.cookieProfile + "\u0000" + Settings.browser
    function followIdentity() { refresh(false); askActive(false) }
    onIdentityChanged: Qt.callLater(followIdentity)

    property Connections sidecarUp: Connections {
        target: typeof sidecar !== "undefined" ? sidecar : null
        function onReadyChanged() { if (sidecar.ready) store.refresh(false) }
    }
    Component.onCompleted: refresh(false)
}
