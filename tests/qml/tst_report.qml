import QtQuick
import QtTest
import "../../src/qml/components"
import "../../src/qml/components/report.js" as Report

// Report…: the details go to the local writer, the folder (or the file, shown)
// and the issue form open, and the form carries the words melo showed, the
// version and the system, and no other detail.
Item {
    width: 420; height: 300

    TestCase {
        name: "Report"
        when: windowShown

        readonly property string form: "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml"

        function cleanup() { Report.setShowFile(null) }

        function test_send_writes_then_opens_folder_and_form() {
            const wrote = [], opened = []
            const writer = { writeReport: (k, d) => { wrote.push([k, d]); return {
                path: "/c/reports/x.txt", folder: "file:///c/reports", version: "0.4.1", system: "Fedora Linux 43" } } }
            Report.send(writer, "download", "", { message: "The download failed.", videoId: "abc", error: "HTTP 403" },
                        (u) => opened.push(u))
            compare(wrote.length, 1)
            compare(wrote[0][0], "download")
            compare(wrote[0][1].videoId, "abc")
            compare(opened, ["file:///c/reports",
                             form + "&title=Download%20failed&what=melo%20said%3A%20The%20download%20failed."
                                  + "&version=0.4.1&system=Fedora%20Linux%2043"])
        }

        function test_the_file_is_shown_where_the_platform_can() {
            const shown = [], opened = []
            Report.setShowFile((p) => shown.push(p))
            Report.send({ writeReport: () => ({ path: "/c/reports/x.txt", folder: "file:///c/reports" }) },
                        "home", "", { message: "Home didn't load." }, (u) => opened.push(u))
            compare(opened.length, 1)
            verify(opened[0].indexOf(form) === 0)
            compare(shown, ["/c/reports/x.txt"])
        }

        function test_url_never_carries_the_details() {
            const opened = []
            Report.send({ writeReport: () => ({}) }, "plugin", "lyrics-plus",
                        { message: "This plugin didn't start.", error: "/home/someone/secret" }, (u) => opened.push(u))
            compare(opened.length, 1)
            verify(opened[0].indexOf("someone") < 0)
            verify(opened[0].indexOf("&title=Plugin%20problem%20(lyrics-plus)") > 0)
        }

        function test_every_kind_that_reports_has_a_title() {
            for (const k of ["playback", "error", "backend", "download", "search", "radio", "plugin",
                             "home", "playlist", "cookies", "tagging", "metadata"])
                verify(Report.title(k, "") !== "Problem", k)
        }
    }
}
