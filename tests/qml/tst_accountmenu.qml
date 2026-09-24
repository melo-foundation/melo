import QtQuick
import QtTest
import "../../src/qml/components/accounts.js" as Accounts

// Which identity melo speaks as, and who that is. The title bar's menu and
// the settings window's account choice are the same list; it is built here
// so the two cannot disagree about what exists, which one is on, or which
// Google account a browser is signed in as.
TestCase {
    name: "AccountMenu"

    readonly property var profiles: ["Default", "Jazz"]
    readonly property var browsers: ["firefox", "chromium"]
    readonly property var ada: ({ signedIn: true, account: { name: "Ada Lovelace", handle: "@ada",
                                                             photo: "https://yt3.ggpht.com/a" } })

    function list(over) {
        const o = { profiles: profiles, browsers: browsers, cookieSource: "guest",
                    cookieProfile: "Default", browser: "chromium", status: {} }
        for (const k in over) o[k] = over[k]
        return Accounts.entries(o)
    }
    function labels(e) { return e.map((x) => x.label) }

    function test_browsers_come_first_then_profiles_then_no_account() {
        compare(labels(list({})), ["Firefox", "Chromium", "Default", "Jazz", "No account"])
    }

    function test_exactly_one_entry_is_active() {
        const e = list({ cookieSource: "browser", browser: "chromium" })
        compare(e.filter((x) => x.active).length, 1)
        compare(e.find((x) => x.active).id, "chromium")
    }

    function test_a_signed_in_browser_says_who_it_is() {
        const e = list({ status: { "browser:chromium": ada } })
        compare(e.find((x) => x.id === "chromium").label, "Chromium · Ada Lovelace")
    }

    function test_a_signed_out_browser_says_so() {
        const e = list({ status: { "browser:firefox": { signedIn: false, account: null } } })
        compare(e.find((x) => x.id === "firefox").label, "Firefox · signed out")
    }

    function test_a_browser_not_asked_about_yet_is_just_its_name() {
        compare(list({}).find((x) => x.id === "firefox").label, "Firefox")
    }

    function test_signed_in_without_a_name_still_says_signed_in() {
        const e = list({ status: { "browser:chromium": { signedIn: true, account: null } } })
        compare(e.find((x) => x.id === "chromium").label, "Chromium · signed in")
    }

    function test_the_browser_in_use_stays_listed_when_detection_misses_it() {
        // a store yt-dlp can still read, in a place the detector does not know
        const e = list({ browsers: ["firefox"], cookieSource: "browser", browser: "brave" })
        const b = e.find((x) => x.id === "brave")
        verify(b)
        verify(b.active)
    }

    function test_no_account_is_always_offered() {
        const n = list({}).find((x) => x.kind === "none")
        verify(n)
        verify(!n.active)
        verify(list({ cookieSource: "none" }).find((x) => x.kind === "none").active)
    }

    function test_nothing_set_up_is_no_account_alone() {
        const e = Accounts.entries({ profiles: [], browsers: [], cookieSource: "guest",
                                     cookieProfile: "", browser: "", status: {} })
        compare(labels(e), ["No account"])
        verify(e[0].active)
    }

    function test_an_unknown_active_profile_marks_nothing() {
        const e = list({ cookieProfile: "gone" })
        compare(e.filter((x) => x.active).length, 0)
    }

    function test_the_title_bar_shows_the_account_name_when_signed_in() {
        const e = list({ cookieSource: "browser", status: { "browser:chromium": ada } })
        compare(Accounts.titleOf(e), "Ada Lovelace")
        compare(Accounts.photoOf(e), "https://yt3.ggpht.com/a")
    }

    function test_the_title_bar_falls_back_to_the_identity_name() {
        compare(Accounts.titleOf(list({ cookieProfile: "Jazz" })), "Jazz")
        compare(Accounts.titleOf(list({ cookieSource: "browser" })), "Chromium")
        compare(Accounts.photoOf(list({ cookieSource: "browser" })), "")
        compare(Accounts.titleOf(list({ cookieProfile: "gone" })), "No account")
    }

    function test_status_keys_match_the_sidecar() {
        compare(Accounts.statusKey("browser", "chromium"), "browser:chromium")
        compare(Accounts.statusKey("guest", "Jazz"), "guest:Jazz")
    }

    function test_the_browser_is_named_the_way_settings_names_it() {
        compare(Accounts.browserLabel("chromium"), "Chromium")
        compare(Accounts.browserLabel("librewolf"), "librewolf")
        compare(Accounts.browserLabel(""), "")
    }

    // what picking an entry writes, and in what order — the title bar and the
    // settings window both pick through this
    // property setters, as Settings has: applyChoice assigns plainly
    function fakeSettings(src, prof, br) {
        const s = { writes: [], v: { cookieSource: src, cookieProfile: prof, browser: br } }
        for (const k of ["cookieSource", "cookieProfile", "browser"])
            Object.defineProperty(s, k, { get() { return this.v[k] },
                                          set(x) { this.v[k] = x; this.writes.push(k) } })
        return s
    }
    function test_picking_a_browser_writes_the_browser_before_the_source() {
        const s = fakeSettings("guest", "Jazz", "firefox")
        Accounts.applyChoice({ kind: "browser", id: "chromium" }, s)
        compare(s.browser, "chromium")
        compare(s.cookieSource, "browser")
        compare(s.writes, ["browser", "cookieSource"])
    }
    function test_picking_a_profile_writes_the_profile_before_the_source() {
        const s = fakeSettings("browser", "Default", "chromium")
        Accounts.applyChoice({ kind: "guest", id: "Jazz" }, s)
        compare(s.writes, ["cookieProfile", "cookieSource"])
        compare(s.cookieSource, "guest")
    }
    function test_picking_what_is_already_on_writes_nothing() {
        const s = fakeSettings("guest", "Jazz", "chromium")
        Accounts.applyChoice({ kind: "guest", id: "Jazz" }, s)
        compare(s.writes, [])
    }
    function test_picking_no_account_leaves_the_rest_alone() {
        const s = fakeSettings("browser", "Jazz", "chromium")
        Accounts.applyChoice({ kind: "none", id: "none" }, s)
        compare(s.writes, ["cookieSource"])
        compare(s.browser, "chromium")
    }
    function test_an_entry_has_a_key_the_settings_select_can_hold() {
        const e = list({})
        compare(e.find((x) => x.id === "chromium").key, "browser:chromium")
        compare(e.find((x) => x.kind === "none").key, "none:none")
    }

    // asking about an identity names it outright, so the answer never depends
    // on whether a settings write has reached the sidecar yet
    function fakeRpc(reply) {
        return { calls: [], rpc(m, p, cb) { this.calls.push({ m: m, p: p }); cb(reply) } }
    }
    function test_asking_about_a_browser_names_the_browser() {
        const host = fakeRpc({ ok: true, result: { signedIn: true, account: { name: "Ada" } } })
        let got = null
        Accounts.askStatus(host, "browser", "chromium", (k, st) => got = { k: k, st: st })
        compare(host.calls[0].m, "cookies/status")
        compare(host.calls[0].p, { source: "browser", browser: "chromium" })
        compare(got.k, "browser:chromium")
        verify(got.st.signedIn)
        compare(got.st.account.name, "Ada")
    }
    function test_asking_about_a_profile_names_the_profile() {
        const host = fakeRpc({ ok: true, result: { signedIn: false } })
        let got = null
        Accounts.askStatus(host, "guest", "Jazz", (k, st) => got = { k: k, st: st })
        compare(host.calls[0].p, { source: "guest", profile: "Jazz" })
        compare(got.st, { signedIn: false, account: null })
    }
    function test_a_failed_ask_reports_nothing() {
        let called = false
        Accounts.askStatus(fakeRpc({ ok: false }), "browser", "firefox", () => called = true)
        verify(!called)
    }

    // a browser's login changes outside melo, so a status asked when a menu
    // opens or melo comes back to the front re-reads the browser's store
    // rather than answer from what was read at start
    function test_a_fresh_ask_tells_the_sidecar_to_reread_the_browser() {
        const host = fakeRpc({ ok: true, result: { signedIn: false } })
        Accounts.askStatus(host, "browser", "chromium", () => {}, true)
        compare(host.calls[0].p, { source: "browser", browser: "chromium", fresh: true })
    }
    function test_a_plain_ask_uses_what_the_sidecar_holds() {
        const host = fakeRpc({ ok: true, result: { signedIn: false } })
        Accounts.askStatus(host, "browser", "chromium", () => {})
        compare(host.calls[0].p, { source: "browser", browser: "chromium" })
    }

    // a browser being re-read says so, rather than show the answer from
    // before — which, right after a sign-in or out, is the wrong one
    function test_a_browser_being_re_read_says_checking() {
        const e = list({ status: { "browser:chromium": ada }, checking: { "browser:chromium": true } })
        compare(e.find((x) => x.id === "chromium").label, "Chromium · checking…")
        // the account it last knew is not claimed while it checks
        compare(e.find((x) => x.id === "chromium").account, null)
    }
    function test_a_failed_ask_reports_its_key_to_the_failure_handler() {
        let failedKey = ""
        Accounts.askStatus(fakeRpc({ ok: false }), "browser", "firefox", () => {}, true, (k) => failedKey = k)
        compare(failedKey, "browser:firefox")
    }
}
