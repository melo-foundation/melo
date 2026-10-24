import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"
import "../../src/qml/components/nowplaying"

// Titles, channel names and lyrics are shown as written: a string Qt would
// guess is rich text (Text.AutoText) must not lose its tags, italicise or
// fetch an <img src>. Real YouTube titles below; BlendText is in tst_blendmodes.
Item {
    id: top
    width: 600; height: 400

    readonly property var samples: [
        "What does :<i> code stand for in subtitles",
        "Difference between <div> and <span> element.",
        "<script>alert(document.domain)</script>",
        "\"><img src=x onerror=prompt(1)>",
        "<img src=\"http://127.0.0.1:9/x.png\"> title"
    ]

    Text { id: ref; textFormat: Text.PlainText; font.pixelSize: 13; font.family: Theme.fontFamily }

    InkText { id: ink; font.pixelSize: 13 }
    ScrollText { id: scroll; width: 2000; font.pixelSize: 13 }
    SkeletonValue { id: skel; width: 2000; font.pixelSize: 13 }
    StyledText { id: styled; width: 2000; height: 20; font.pixelSize: 13 }
    HueLumText { id: huelum; width: 2000; height: 20; font.pixelSize: 13 }
    NpWords { id: wordsBlock; width: 600; height: 100 }
    NpWords { id: wordsLines; width: 600; height: 100 }

    function texts(item, out) {
        if (item.textFormat !== undefined && item.text !== undefined && item.text.length > 0)
            out.push(item)
        for (let i = 0; i < item.children.length; ++i) texts(item.children[i], out)
        if (item.contentItem) texts(item.contentItem, out)
        return out
    }

    TestCase {
        name: "PlainText"
        when: windowShown

        function check(root, s) {
            const found = top.texts(root, [])
            verify(found.length > 0, "no Text under " + root)
            for (const t of found) {
                compare(t.textFormat, Text.PlainText, "format of " + t + " for " + s)
                compare(t.text, s)
            }
        }

        function test_components() {
            for (const s of top.samples) {
                for (const c of [ink, scroll, skel, styled, huelum]) {
                    c.text = s
                    check(c, s)
                }
                ref.text = s
                compare(ink.implicitWidth, ref.implicitWidth, "laid out as written: " + s)
                compare(ink.lineCount, 1)
            }
        }

        function test_lyrics() {
            for (const s of top.samples) {
                wordsBlock.np = { lines: [], plain: s, activeLine: -1 }
                check(wordsBlock, s)
                wordsLines.np = { lines: [{ t: 0, text: s }], plain: "", activeLine: -1 }
                wait(0)
                check(wordsLines, s)
            }
        }
    }
}
