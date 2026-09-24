import QtQuick
import QtQuick.Window
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
//   qmltestrunner-qt6 -input tests/qml/tst_imagefills.qml
Item {
    id: scene
    width: 320; height: 240
    StyledFill { id: fill; width: 120; height: 72; local: true; kind: "image" }
    Item {
        width: 0; height: 0; clip: true
        Rectangle { id: rounded; width: fill.width; height: fill.height; radius: 16; color: "white"; layer.enabled: true }
    }
    TestCase {
        name: "ImageFills"; when: windowShown
        readonly property string grid: Qt.resolvedUrl("data/image-grid.svg").toString()
        readonly property string ramp: Qt.resolvedUrl("data/image-ramp.png").toString()
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function init() {
            if (scene.GraphicsInfo.api === GraphicsInfo.Software) skip("image fills require an RHI backend")
            failOnWarning(/Failed to (compile shader|build graphics pipeline)|Unable to assign|ReferenceError|TypeError/)
            fill.x = 0; fill.y = 0; fill.width = 120; fill.height = 72
            fill.local = true; fill.layers = null; fill.mask = null
            fill.rad = Qt.vector4d(-1,-1,-1,-1)
        }
        function entry(own, src, scale) {
            return { colour: "#ffffff", source: "image", params: { src: src || grid, speed: 0,
                scale: scale === undefined ? 1 : scale, angle: 0, own: own || {} } }
        }
        function setImage(own, src, scale) {
            fill.layers = Theme.layersOf(entry(own, src, scale))
            const layer = findChild(fill, "fillLayer_0")
            tryVerify(() => layer.picture !== null && layer.picture.status === Image.Ready)
            wait(50)
            return layer
        }
        // qmltestrunner's window has no alpha, so grab over black and over
        // white: the difference gives the fill's alpha, and the black grab its
        // premultiplied colour.
        function shot(time) {
            Theme.clock = time || 0; wait(40)
            const win = scene.Window.window
            win.color = "black"; const dark = grabImage(fill)
            win.color = "white"; const light = grabImage(fill)
            return {
                width: dark.width, height: dark.height, dark: dark, light: light,
                red: (x, y) => dark.red(x, y),
                green: (x, y) => dark.green(x, y),
                blue: (x, y) => dark.blue(x, y),
                alpha: (x, y) => 255 - Math.max(light.red(x, y) - dark.red(x, y),
                                                light.green(x, y) - dark.green(x, y),
                                                light.blue(x, y) - dark.blue(x, y)),
                equals: other => dark.equals(other.dark) && light.equals(other.light)
            }
        }
        function rgb(image, x, y, values) {
            fuzzyCompare(image.red(x,y), values[0], 3)
            fuzzyCompare(image.green(x,y), values[1], 3)
            fuzzyCompare(image.blue(x,y), values[2], 3)
        }
        function test_native_side_anchors_data() {
            return Theme.imageAnchors.map((name, index) => ({ tag: name, anchor: index }))
        }
        function test_native_side_anchors(data) {
            const layer = setImage({fit:4, anchor:data.anchor})
            compare(layer.picture.implicitWidth, 24, "native source was not resized to 1024")
            compare(layer.picture.implicitHeight, 18)
            for (const size of [[120,72],[176,113]]) {
                fill.width = size[0]; fill.height = size[1]
                const image = shot(), ax = (data.anchor % 3) / 2, ay = Math.floor(data.anchor / 3) / 2
                const x = Math.round((fill.width-24)*ax), y = Math.round((fill.height-18)*ay)
                rgb(image, x+3, y+2, [255,0,0])
                rgb(image, x+20, y+14, [255,128,0])
                if (x > 0) compare(image.alpha(0,y+2), 0)
                if (y > 0) compare(image.alpha(x+3,0), 0)
            }
        }
        function test_cover_and_contain_follow_the_chosen_edge() {
            setImage({fit:1, anchor:0}); const top = shot()
            setImage({fit:1, anchor:8}); const bottom = shot()
            rgb(top,5,20,[255,0,0]); rgb(bottom,5,20,[255,255,0])
            setImage({fit:2, anchor:0}); const left = shot()
            setImage({fit:2, anchor:2}); const right = shot()
            rgb(left,5,5,[255,0,0]); compare(left.alpha(115,5),0)
            compare(right.alpha(5,5),0); rgb(right,29,5,[255,0,0])
        }
        function test_zoom_keeps_the_chosen_source_point_at_the_anchor() {
            let reference = null
            for (const zoom of [0.5,1,2,4]) {
                setImage({fit:4, anchor:4, focusX:0.25, focusY:0.75}, ramp, 1/zoom)
                const image = shot()
                rgb(image,60,36,[60,180,64])
                if (reference) {
                    fuzzyCompare(image.red(60,36),reference.red(60,36),3)
                    fuzzyCompare(image.green(60,36),reference.green(60,36),3)
                }
                reference = image
            }
            fill.width = 180; fill.height = 110
            rgb(shot(),90,55,[60,180,64])
        }
        function test_cover_clamps_focus_at_the_picture_edges() {
            for (const point of [0,1]) {
                setImage({fit:1, anchor:4, focusX:point, focusY:point})
                const image = shot()
                for (const p of [[1,1],[118,1],[1,70],[118,70]]) compare(image.alpha(p[0],p[1]),255)
            }
        }
        readonly property var cuts: ({fit:5, sliceLeft:8, sliceRight:8, sliceTop:6, sliceBottom:6})
        function test_nine_slice_keeps_corners_and_stretches_the_middle() {
            setImage(cuts)
            for (const size of [[120,72],[233,97],[40,120]]) {
                fill.width = size[0]; fill.height = size[1]
                const image = shot(), w = fill.width, h = fill.height
                rgb(image,2,2,[255,0,0]); rgb(image,w-3,2,[0,0,255])
                rgb(image,2,h-3,[255,255,255]); rgb(image,w-3,h-3,[255,128,0])
                rgb(image,11,2,[0,255,0]); rgb(image,2,10,[255,255,0])
                rgb(image,Math.floor(w/2),Math.floor(h/2),[0,255,255])
            }
        }
        function test_nine_slice_zoom_changes_caps_not_the_frame() {
            setImage(cuts); const normal = shot()
            setImage(cuts,grid,0.5); const large = shot()
            rgb(normal,11,2,[0,255,0]); rgb(large,11,2,[255,0,0])
            rgb(large,117,69,[255,128,0]); rgb(large,60,36,[0,255,255])
        }
        function test_nine_slice_tiny_targets_and_oversized_cuts() {
            setImage({fit:5,sliceLeft:255,sliceRight:255,sliceTop:255,sliceBottom:255})
            for (const size of [[9,7],[1,1],[25,9]]) {
                fill.width = size[0]; fill.height = size[1]
                const image = shot()
                for (let y=0; y<image.height; ++y) for (let x=0; x<image.width; ++x) compare(image.alpha(x,y),255)
            }
        }
        function test_nine_slice_ignores_motion_rotation_and_space() {
            fill.local = false
            const e = entry(cuts)
            e.params.speed = 0.8; e.params.angle = 145; e.space = "window"
            fill.layers = Theme.layersOf(e)
            wait(100)
            const layer = findChild(fill,"fillLayer_0")
            tryVerify(() => layer.picture && layer.picture.status === Image.Ready)
            verify(layer.inItem); verify(!layer.animated); verify(!Theme.entryMoves(e))
            verify(shot(0).equals(shot(9)))
            rgb(shot(),2,2,[255,0,0])
        }
        function test_source_transparency_and_shape_coverage_survive() {
            setImage(cuts,ramp)
            fill.mask = rounded
            let image = shot()
            compare(image.alpha(0,0),0)
            compare(image.alpha(60,36),0, "transparent source centre stays a hole")
            compare(image.alpha(60,3),255)
            // The image's band must use the rounded silhouette, not the box.
            const e = entry({fit:3}); e.mask = "edge"; e.maskDist = 3
            fill.layers = Theme.layersOf(e); fill.rad = Qt.vector4d(16,16,16,16)
            image = shot()
            verify(image.alpha(6,6)>240, "rounded corner is inside the edge band")
            compare(image.alpha(12,12),0)
            compare(image.alpha(60,36),0)
        }
        function test_fitted_window_space_uses_the_window_edges() {
            fill.local = false
            fill.x = scene.Window.window.width - fill.width
            fill.y = scene.Window.window.height - fill.height
            fill.updateOrigin()
            setImage({fit:4,anchor:8})
            const layer = findChild(fill,"fillLayer_0")
            compare(layer.imageGeometry.z, scene.Window.window.width)
            rgb(shot(),99,56,[255,0,0])
            fill.x = 0; fill.y = 0; fill.updateOrigin()
            compare(shot().alpha(99,56),0, "image is on the window's edge, not each item's")
        }
        function test_image_options_survive_a_filter_chain() {
            const e = entry(cuts)
            fill.layers = Theme.layersOf({ layers: [e, {source:"invert"}] })
            wait(150)
            const image = shot()
            rgb(image,2,2,[0,255,255]); rgb(image,60,36,[255,0,0])
        }
        function test_empty_source_is_transparent() {
            fill.layers = Theme.layersOf({source:"image",params:{src:"",speed:0}})
            compare(shot().alpha(60,36),0)
        }
    }
}
