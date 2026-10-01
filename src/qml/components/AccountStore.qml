pragma Singleton
import QtQuick
import "accounts.js" as Accounts

// The accounts, held once, so the title-bar menu, the wizard's dropdown and
// the settings window's Account choice change together.
// Every browser is re-read on a switch (the sidecar dropped its cookies) and
// when an account menu opens, since the menus list them all. Melo returning to
// the front re-reads only the browser in use.
QtObject {
    id: store

    property var profiles: []
    property var browsers: []
    // cookies/status answers, keyed Accounts.statusKey(kind, id)
    property var status: ({})
    // Browser re-reads in flight, shown as checking until they land.
    property var checking: ({})
    function settle(key) {
        if (!(key in store.checking)) return
        const c = Object.assign({}, store.checking); delete c[key]; store.checking = c
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
            const c = Object.assign({}, store.checking); c[key] = true; store.checking = c
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
    // and the settings window, usually after a sign-in or out in the browser.
    // At most every 5 seconds: a read costs about 2 s of CPU. It also drops
    // the sidecar's copy of the cookies, which home and library use.
    property double lastFront: 0
    function cameToFront() {
        if (Date.now() - lastFront < 5000) return
        lastFront = Date.now()
        const b = Accounts.frontRead(Settings.cookieSource, Settings.browser)
        if (b) ask("browser", b, true)
    }
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
