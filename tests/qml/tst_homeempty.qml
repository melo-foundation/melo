import QtQuick
import QtTest
import "../../src/qml/components/homeempty.js" as Empty

// What an empty home is allowed to claim. The feed comes back with nothing
// for several different reasons and melo can tell most of them apart, so it
// names the one it knows rather than asserting a cause that is false in
// states it could have checked.
TestCase {
    name: "HomeEmpty"

    function base() {
        return { loadedOnce: true, loading: false, error: "", count: 0,
                 cookieSource: "guest", sendPlayback: true, signedIn: false }
    }
    function withT(k, v) { const s = base(); s[k] = v; return s }

    function test_nothing_is_said_before_the_first_load_resolves() {
        compare(Empty.emptyState(withT("loadedOnce", false)), null)
        compare(Empty.emptyState(withT("loading", true)), null)
    }

    function test_nothing_is_said_when_the_feed_has_content() {
        compare(Empty.emptyState(withT("count", 30)), null)
    }

    function test_the_error_surface_keeps_its_own_message() {
        compare(Empty.emptyState(withT("error", "Failed to load recommendations")), null)
    }

    function test_no_session_when_cookies_are_off() {
        compare(Empty.emptyState(withT("cookieSource", "none")).line, "No session")
    }

    function test_reporting_off_never_claims_to_be_the_cause() {
        // sendPlayback off yields a GENERIC feed, not an empty one, so it is
        // never why the page is bare — it only withdraws the advice, because
        // playing cannot build history melo is not reporting
        const s = Empty.emptyState(withT("sendPlayback", false))
        compare(s.line, "No recommendations")
        compare(s.actions, undefined)
    }

    function test_a_new_session_is_never_told_suggestions_are_off() {
        // the default is on; a fresh profile must get the actionable line
        compare(Empty.emptyState(base()).line, "Play something to build suggestions")
    }

    function test_a_signed_in_account_does_not_care_what_melo_reports() {
        // the account's recommendations come from its own watch history,
        // built wherever the user browses; melo's reporting is not the source
        const s = base(); s.cookieSource = "browser"; s.signedIn = true; s.sendPlayback = false
        compare(Empty.emptyState(s).line, "Watch history is off")
    }

    function test_browser_cookies_that_are_not_signed_in_are_not_suggestions_off() {
        // extraction can succeed and still carry no session
        const s = base(); s.cookieSource = "browser"; s.signedIn = false; s.sendPlayback = false
        compare(Empty.emptyState(s).line, "No recommendations")
    }

    function test_a_signed_in_account_with_an_empty_feed_names_the_history_setting() {
        const s = Empty.emptyState(withT("signedIn", true))
        compare(s.line, "Watch history is off")
        compare(s.actions, ["history", "guest"])
    }

    function test_a_guest_with_an_empty_feed_is_told_how_to_fill_it() {
        const s = Empty.emptyState(base())
        compare(s.line, "Play something to build suggestions")
        compare(s.actions, undefined)
    }

    function test_no_session_outranks_everything() {
        const s = base(); s.cookieSource = "none"; s.signedIn = true; s.sendPlayback = false
        compare(Empty.emptyState(s).line, "No session")
    }
}
