import QtQuick
import QtTest
import "../../src/qml/components/errortext.js" as ErrorText

// Every failure's words: what happened and what to do, never the backend's
// own line; Report… only where melo cannot say why; one cause, one wording.
TestCase {
    name: "ErrorText"

    // [function, raw line, words, fix, report]
    function test_words_fix_and_report_data() {
        const net = "Check your connection and try again."
        return [
            { tag: "search offline", f: "search", raw: "fetch failed", text: "Search didn't load. " + net, fix: "retry", report: false },
            { tag: "search unknown", f: "search", raw: "TypeError: x is undefined", text: "Search didn't load.", fix: "retry", report: true },
            { tag: "download private", f: "download", raw: "ERROR: [youtube] abc: Video unavailable. This video is private",
              text: "YouTube says this video is unavailable.", fix: "", report: false },
            { tag: "download offline", f: "download", raw: "Unable to download webpage: <urlopen error [Errno -3]>",
              text: "The download stopped. " + net, fix: "retry", report: false },
            { tag: "download disk", f: "download", raw: "OSError: [Errno 28] No space left on device",
              text: "The disk is full. Free some space.", fix: "", report: false },
            { tag: "download server", f: "download", raw: "ERROR: Unable to download webpage: HTTP Error 503: Service Temporarily Unavailable",
              text: "The download stopped. YouTube had a problem. Try again.", fix: "retry", report: false },
            { tag: "download refused", f: "download", raw: "ERROR: Unable to download webpage: HTTP Error 403: Forbidden",
              text: "The download failed.", fix: "retry", report: true },
            { tag: "download folder", f: "download", raw: "PermissionError: [Errno 13] Permission denied: '/music/x.opus'",
              text: "melo can't write to the download folder. Pick another one in Settings.",
              fix: "settings", report: false },
            { tag: "download no yt-dlp", f: "download", raw: "yt-dlp could not be downloaded; check the connection and try again",
              text: "yt-dlp didn't download. " + net, fix: "retry", report: false },
            { tag: "download unknown", f: "download", raw: "KeyError: 'formats'", text: "The download failed.", fix: "retry", report: true },
            { tag: "radio offline", f: "radio", raw: "fetch failed", text: "The radio didn't start. Check your connection.", fix: "", report: false },
            { tag: "home offline", f: "home", raw: "fetch failed", text: "Home didn't load. " + net, fix: "retry", report: false },
            { tag: "home unknown", f: "home", raw: "Cannot read properties of undefined", text: "Home didn't load.", fix: "retry", report: true },
            { tag: "playlist gone", f: "playlist", raw: "The playlist does not exist.",
              text: "YouTube says this playlist is unavailable.", fix: "", report: false },
            { tag: "playlist offline", f: "playlist", raw: "timeout", text: "The playlist didn't load. " + net, fix: "retry", report: false },
            { tag: "tagging offline", f: "tagging", raw: "request to musicbrainz.org timed out",
              text: "The tag services didn't answer. Check your connection.", fix: "", report: false },
            { tag: "tagging key", f: "tagging", raw: "Last.fm: Invalid API key", text: "Last.fm refused the API key. Check the key.", fix: "", report: false },
            { tag: "file missing", f: "metadataFile", raw: "file not found", text: "That file can't be found.", fix: "", report: false },
            { tag: "file not audio", f: "metadataFile", raw: "not an audio file", text: "That isn't an audio file.", fix: "", report: false },
            { tag: "no folder", f: "metadataFile", raw: "no download folder is set", text: "Set a download folder in Settings first.", fix: "settings", report: false },
            { tag: "file unreadable", f: "metadataFile", raw: "the file cannot be read", text: "That file can't be read.", fix: "", report: false },
            { tag: "file folder", f: "metadataFile", raw: "EACCES: permission denied, copyfile", text: "melo can't write to the download folder. Pick another one in Settings.", fix: "settings", report: false },
            { tag: "file unknown", f: "metadataFile", raw: "this entry cannot hold a file", text: "The replacement didn't go through.", fix: "", report: true },
            { tag: "bad link", f: "metadataLink", raw: "not a YouTube link", text: "That isn't a YouTube link.", fix: "", report: false },
        ]
    }
    function test_words_fix_and_report(data) {
        const t = ErrorText[data.f](data.raw)
        compare(t.text, data.text)
        compare(t.fix, data.fix)
        compare(t.report, data.report)
        verify(t.text.indexOf(data.raw) < 0, "the backend's line never shows")
    }

    function test_cookie_import_names_the_browser_and_the_fix() {
        compare(ErrorText.cookieImport("could not find firefox cookies database in /home/u/.mozilla", "Firefox").text,
                "No Firefox cookies were found. Pick the browser you use YouTube in.")
        compare(ErrorText.cookieImport("database is locked", "Chrome").text, "Close Chrome, then import again.")
        verify(!ErrorText.cookieImport("could not find firefox cookies database", "Firefox").report)
        verify(!ErrorText.cookieImport("secretstorage not available", "Chromium").report)
        verify(ErrorText.cookieImport("Something else entirely", "Firefox").report)
    }

    function test_plugins_report_only_to_melo_for_its_own() {
        compare(ErrorText.plugin({ id: "soundcloud", state: "crashed", error: "exited (code 1) too often; parked" }).text,
                "This plugin kept crashing and was stopped.")
        verify(ErrorText.plugin({ id: "soundcloud", state: "crashed" }).report)
        verify(!ErrorText.plugin({ id: "someone-elses", state: "error", error: "no activate" }).report)
        compare(ErrorText.plugin({ id: "x", state: "running" }), null)
    }

    // the surfaces another one already covers raise nothing of their own
    function test_backend_failures_have_one_surface() {
        compare(ErrorText.rpc("sidecar"), null)       // the backend bar says it
        compare(ErrorText.rpc("initialize"), null)
        compare(ErrorText.rpc("search"), null)        // search's own bar
        compare(ErrorText.rpc("plugins/rescan").text, "The plugin change didn't go through.")
        verify(ErrorText.rpc("plugins/rescan").report)
    }

    // the yt-dlp download failing reads the same in the dialog and the download bar
    function test_one_cause_one_wording() {
        const raw = "yt-dlp could not be downloaded; check the connection and try again"
        compare(ErrorText.play("other", raw, false).text, ErrorText.download(raw).text)
        compare(ErrorText.home("fetch failed").text.indexOf("Check your connection"),
                ErrorText.home("fetch failed").text.length - "Check your connection and try again.".length)
    }
}
