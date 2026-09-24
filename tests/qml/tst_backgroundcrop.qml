import QtQuick
import QtTest
import "../../src/qml/components"

// Cover-and-crop for the image background: the drawn aspect equals the
// source's, the frame stays covered at every window shape, and the crop point
// moves the picture (on a mini bar it is the only way to reach the overflow).
Item {
    id: harness
    width: 400; height: 400

    // A 4:3 stand-in for a photo. No file needed: sourceSize is what the
    // maths reads, and setting it directly is the same input.
    property real srcW: 3508
    property real srcH: 2480
    property real cropX: 0.5
    property real cropY: 0.5
    property string fit: "cover"

    Item {
        id: frame
        anchors.fill: parent
        clip: true
        readonly property real coverScale: harness.fit === "contain"
            ? Math.min(width / harness.srcW, height / harness.srcH)
            : Math.max(width / harness.srcW, height / harness.srcH)
        function cropOffset(box, drawn, point) {
            const over = box - drawn
            return Math.max(Math.min(0, over),
                   Math.min(Math.max(0, over), box / 2 - point * drawn))
        }
        readonly property bool stretch: harness.fit === "stretch"
        Rectangle {
            id: pic
            width: frame.stretch ? frame.width : harness.srcW * frame.coverScale
            height: frame.stretch ? frame.height : harness.srcH * frame.coverScale
            x: frame.cropOffset(frame.width, width, harness.cropX)
            y: frame.cropOffset(frame.height, height, harness.cropY)
        }
    }

    TestCase {
        name: "BackgroundCover"
        when: windowShown

        function shapes() {
            return [ { w: 900, h: 600 }, { w: 1370, h: 1620 }, { w: 1920, h: 400 },
                     { w: 400, h: 1200 }, { w: 1370, h: 90 }, { w: 300, h: 300 } ]
        }

        function test_aspect_is_never_distorted() {
            const want = harness.srcW / harness.srcH
            const s = shapes()
            for (let i = 0; i < s.length; ++i) {
                harness.width = s[i].w; harness.height = s[i].h
                fuzzyCompare(pic.width / pic.height, want, 0.001,
                             "aspect changed at " + s[i].w + "x" + s[i].h)
            }
        }

        function test_frame_stays_covered() {
            const s = shapes()
            for (let i = 0; i < s.length; ++i) {
                harness.width = s[i].w; harness.height = s[i].h
                verify(pic.width >= frame.width - 0.5,
                       "bare horizontally at " + s[i].w + "x" + s[i].h)
                verify(pic.height >= frame.height - 0.5,
                       "bare vertically at " + s[i].w + "x" + s[i].h)
            }
        }

        function test_crop_point_moves_the_picture() {
            // a wide window on a 4:3 source: the overflow is vertical
            harness.width = 1370; harness.height = 90
            harness.cropY = 0
            const top = pic.y
            harness.cropY = 1
            const bottom = pic.y
            compare(top, 0, "cropY 0 should sit the top edge on the frame")
            verify(bottom < top - 100, "cropY 1 barely moved: " + top + " -> " + bottom)
            fuzzyCompare(bottom, frame.height - pic.height, 0.5,
                         "cropY 1 should sit the bottom edge on the frame")
            harness.cropY = 0.5
            fuzzyCompare(pic.y, (frame.height - pic.height) / 2, 0.5,
                         "0.5 must stay the centred crop every theme already has")
        }

        // The point you pick lands in the middle. Edge interpolation agrees
        // with this at 0, 0.5 and 1, so only the values between it catch.
        function test_chosen_point_lands_at_the_centre() {
            harness.width = 1370; harness.height = 90
            const pts = [0.2, 0.35, 0.5, 0.65, 0.8]
            for (let i = 0; i < pts.length; ++i) {
                harness.cropY = pts[i]
                fuzzyCompare(pic.y + pts[i] * pic.height, frame.height / 2, 0.5,
                             "point " + pts[i] + " did not land in the middle")
            }
            harness.cropY = 0.5
        }

        // ...unless it cannot: a point near the edge would pull the picture
        // off the frame, so it stops at the edge and the frame stays covered.
        function test_unreachable_point_stops_at_the_edge() {
            harness.width = 1370; harness.height = 90
            harness.cropY = 0.01
            compare(pic.y, 0, "should have stopped with the top edge on the frame")
            harness.cropY = 0.99
            fuzzyCompare(pic.y, frame.height - pic.height, 0.5,
                         "should have stopped with the bottom edge on the frame")
            harness.cropY = 0.5
        }

        function test_stretch_lands_exactly_on_the_frame() {
            harness.fit = "stretch"
            const s = shapes()
            for (let i = 0; i < s.length; ++i) {
                harness.width = s[i].w; harness.height = s[i].h
                fuzzyCompare(pic.width, frame.width, 0.5, "width off at " + s[i].w)
                fuzzyCompare(pic.height, frame.height, 0.5, "height off at " + s[i].h)
                compare(pic.x, 0, "stretch leaves nothing to crop"); compare(pic.y, 0)
            }
            harness.fit = "cover"
        }

        function test_contain_fits_instead_of_covering() {
            harness.fit = "contain"
            harness.width = 1370; harness.height = 1620
            verify(pic.width <= frame.width + 0.5 && pic.height <= frame.height + 0.5,
                   "contain must not overflow")
            harness.fit = "cover"
        }
    }
}
