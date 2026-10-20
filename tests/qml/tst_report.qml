import QtQuick
import QtTest
import "../../src/qml/components"
import "../../src/qml/components/report.js" as Report

// Report…: the details go to the local writer, the folder and the issue form
// open, and the form's URL names the error's kind and nothing else.
Item {
    width: 420; height: 300

    TestCase {
        name: "Report"
        when: windowShown

        function test_send_writes_then_opens_folder_and_form() {
            const wrote = [], opened = []
            const writer = { writeReport: (k, d) => { wrote.push([k, d]); return { path: "/c/reports/x.txt", folder: "file:///c/reports" } } }
            Report.send(writer, "download", "", { videoId: "abc", error: "HTTP 403" }, (u) => opened.push(u))
            compare(wrote.length, 1)
            compare(wrote[0][0], "download")
            compare(wrote[0][1].videoId, "abc")
            compare(opened, ["file:///c/reports",
                             "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml&title=Download%20failed"])
        }

        function test_url_never_carries_the_details() {
            const opened = []
            Report.send({ writeReport: () => ({}) }, "plugin", "lyrics-plus", { error: "/home/someone/secret" }, (u) => opened.push(u))
            compare(opened.length, 1)
            verify(opened[0].indexOf("someone") < 0)
            verify(opened[0].endsWith("&title=Plugin%20problem%20(lyrics-plus)"))
        }

        function test_every_kind_has_a_title() {
            for (const k of ["playback", "error", "backend", "node", "ytdlp", "download", "plugin", "gstreamer",
                             "blur", "home", "playlist", "cookies", "tagging", "metadata"])
                verify(Report.title(k, "") !== "Problem", k)
        }
    }
}
