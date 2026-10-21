import QtQuick
import QtQuick.Window
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// An adaptive reader over the video samples the video, not what is under it:
// the picture is copied into its window's ground, and follows every frame.
// The pixel cases need an RHI backend:
// QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
//     qmltestrunner -input tests/qml/tst_groundvideo.qml
Rectangle {
    id: scene
    width: 200; height: 220
    color: "black"
    // Main's `Theme.anyAdaptive`: off, the ground is never a layer
    property bool anyAdaptive: true

    // Main's shape: the ground, then a view holding the video and a reader over it.
    // mainContent hides in mini mode, where the popup's readers still read it.
    Item {
        id: mainContent
        anchors.fill: parent
        Item {
            id: ground
            anchors.fill: parent
            layer.enabled: scene.anyAdaptive && Theme.adaptiveUsers > 0
            readonly property Item readItem: groundRead.texture
            Rectangle { width: 200; height: 100; color: "#202020" }
            // below it, a ramp both ways: a reader reading the wrong place shows
            Item {
                y: 100; width: 200; height: 120
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "#ffffff" }
                        GradientStop { position: 1; color: "#808080" }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    opacity: 0.5
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#000000" }
                        GradientStop { position: 1; color: "#ffffff" }
                    }
                }
            }
        }
        GroundPictures { id: groundRead; base: ground }
    }
    Item {
        id: view
        anchors.fill: parent
        GroundPicture {
            id: picture
            x: 100; width: 100; height: 100
            Rectangle { id: video; anchors.fill: parent; color: "#e0e0e0" }   // the VideoSurface's place
        }
        HueLum { id: reader; x: 120; y: 20; width: 40; height: 40; backdrop: Theme.backdrop; lum: -1 }
        // Fit: the picture item covers the page, the frame is painted in part of it
        GroundPicture {
            id: fitPicture
            visible: false   // shown by the Fit cases only
            y: 100; width: 200; height: 120
            Rectangle { id: fitFrame; color: "#101010" }   // where the VideoSurface paints
        }
        HueLum { id: fitReader; y: 100; width: 200; height: 120; backdrop: Theme.backdrop; lum: -1 }
    }

    // a secondary window with a ground of its own, as MeloWindow has
    Window {
        id: second
        width: 100; height: 100
        color: "black"
        readonly property Item meloGround: secondGround
        Item {
            id: secondGround
            width: 100; height: 100
            property int groundReaders: 0
            layer.enabled: groundReaders > 0
            readonly property Item readItem: secondRead.texture
            Rectangle { anchors.fill: parent; color: "#202020" }
        }
        GroundPictures { id: secondRead; base: secondGround }
        GroundPicture {
            id: secondPicture
            width: 100; height: 100
            Rectangle { id: secondVideo; anchors.fill: parent; color: "#e0e0e0" }
        }
        HueLum { id: secondReader; x: 30; y: 30; width: 40; height: 40; backdrop: Theme.backdrop; lum: -1 }
    }

    Window { id: bare }

    Component { id: lateReader; HueLum { width: 20; height: 20; lum: -1 } }

    TestCase {
        name: "GroundVideo"
        when: windowShown

        function initTestCase() {
            failOnWarning(/Cannot use same item on different windows/)
            failOnWarning(/Binding loop/)
            Theme.backdrop = ground
        }
        function cleanupTestCase() { second.visible = false }
        function gpu() { return scene.GraphicsInfo.api !== GraphicsInfo.Software }
        function grey(c) { return Math.round(c.r * 255) }

        function test_a_picture_joins_the_ground_while_it_is_read() {
            tryCompare(ground.layer, "enabled", true)
            verify(Theme.groundPictures.indexOf(picture) >= 0, "the picture is in the ground")
            verify(picture.layer.enabled, "and its layer is the texture the ground copies")
            compare(groundRead.texture, groundRead.children[0], "readers sample the ground with the picture in it")
            compare(reader.src, groundRead.texture)
            const copy = groundRead.children[0].children.find(c => c.modelData === picture)
            verify(copy !== undefined)
            compare(Qt.rect(copy.x, copy.y, copy.width, copy.height), Qt.rect(100, 0, 100, 100))
        }

        function test_a_hidden_picture_leaves_the_ground() {
            picture.visible = false
            verify(Theme.groundPictures.indexOf(picture) < 0)
            verify(!picture.layer.enabled)
            compare(reader.src, ground, "with no picture the ground is read as it is")
            picture.visible = true
            verify(Theme.groundPictures.indexOf(picture) >= 0)
        }

        function test_the_reader_over_the_video_reads_the_video() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            video.color = "#e0e0e0"
            waitForRendering(scene)
            const img = grabImage(scene)
            // lum -1 inverts: #e0e0e0 under it gives #1f1f1f, the ground's #202020 would give #dfdfdf
            fuzzyCompare(grey(img.pixel(140, 40)), 0x1f, 2)
            fuzzyCompare(grey(img.pixel(40, 40)), 0x20, 2, "off the reader, the ground shows")
        }

        function test_the_reader_follows_every_frame() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            for (let i = 0; i < 5; ++i) {
                const v = 0.1 + i * 0.2
                video.color = Qt.rgba(v, v, v, 1)
                const img = grabImage(scene)
                fuzzyCompare(grey(img.pixel(140, 40)), 255 - Math.round(v * 255), 3, "frame " + i)
            }
        }

        function test_a_hidden_ground_is_still_read() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            mainContent.visible = false
            video.color = "#e0e0e0"
            const img = grabImage(scene)
            mainContent.visible = true
            fuzzyCompare(grey(img.pixel(140, 40)), 0x1f, 2)
        }

        function test_a_translucent_picture_mixes_with_the_ground() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            video.color = "#e0e0e0"
            picture.opacity = 0.5
            const img = grabImage(scene)
            picture.opacity = 1
            const under = Math.round((0xe0 + 0x20) / 2)
            fuzzyCompare(grey(img.pixel(110, 80)), under, 3, "what is on screen")
            fuzzyCompare(grey(img.pixel(140, 40)), 255 - under, 3, "is what the reader reads")
        }

        function test_a_reader_in_another_window_reads_that_windows_ground() {
            second.visible = true
            tryCompare(second, "visible", true)
            verify(Theme.readable(Theme.backdrop, second), "the main ground is not readable there, its own is")
            compare(secondReader.ground, secondGround)
            verify(secondReader.ready)
            tryCompare(secondGround, "groundReaders", 1)
            tryCompare(secondGround.layer, "enabled", true)
            verify(Theme.groundPictures.indexOf(secondPicture) >= 0)
            if (!gpu()) return
            secondVideo.color = "#e0e0e0"
            waitForRendering(second.contentItem)
            fuzzyCompare(grey(grabImage(second.contentItem).pixel(50, 50)), 0x1f, 2)
        }

        // A reader that meets its window late must not turn a ground's layers on:
        // those follow the readers' count and the palette, never a reader's write.
        function test_a_late_reader_leaves_the_ground_layers_alone() {
            scene.anyAdaptive = false
            const tex = groundRead.children[0]
            verify(!ground.layer.enabled)
            verify(!tex.layer.enabled)
            const r = lateReader.createObject(null, { backdrop: Theme.backdrop })
            r.parent = view
            wait(50)
            compare(r.src, tex)
            verify(!tex.layer.enabled, "the read texture is not forced on")
            verify(!ground.layer.enabled, "nor the ground")
            scene.anyAdaptive = true
            tryCompare(tex.layer, "enabled", true)
            r.destroy()
        }

        // The over-artwork words' outline adapts by default: a palette with no
        // adaptive role still has a reader of the ground on Now Playing.
        function test_an_adaptive_halo_counts_as_adaptive() {
            const keys = Object.keys(Theme.p)
            const saved = {}
            for (const k of keys) saved[k] = Theme.p[k]
            for (const k of keys) delete Theme.p[k]
            Theme.p.text = "#141414"; Theme.p.textOverArt = "#ffffff"; Theme.p.window = "#ebe9ed"
            Theme.pChanged()
            compare(Theme.sourceOf(Theme.inkRole("textOverArt").effect.colour), "adaptive")
            verify(Theme.anyAdaptive, "the ground can be a layer for it")
            for (const k of Object.keys(Theme.p)) delete Theme.p[k]
            for (const k of keys) Theme.p[k] = saved[k]
            Theme.pChanged()
        }

        // Off the painted frame a reader reads exactly the ground; on it, the frame.
        function fitCase(frame) {
            tryCompare(ground.layer, "enabled", true)
            fitFrame.x = frame.x; fitFrame.y = frame.y; fitFrame.width = frame.width; fitFrame.height = frame.height
            // the reference: no picture anywhere, so the reader samples the ground itself
            picture.visible = false
            fitPicture.visible = false
            waitForRendering(scene)
            compare(fitReader.src, ground)
            const bare = grabImage(scene)
            fitPicture.visible = true
            waitForRendering(scene)
            compare(fitReader.src, groundRead.texture)
            const shown = grabImage(scene)
            fitPicture.visible = false
            picture.visible = true
            let off = 0, on = 0
            for (let y = 2; y < 120; y += 4) for (let x = 2; x < 200; x += 4) {
                const inFrame = x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
                const edge = Math.abs(x - frame.x) < 2 || Math.abs(x - frame.x - frame.width) < 2
                          || Math.abs(y - frame.y) < 2 || Math.abs(y - frame.y - frame.height) < 2
                if (edge) continue
                const a = shown.pixel(x, y + 100), b = bare.pixel(x, y + 100)
                if (inFrame) {
                    fuzzyCompare(grey(a), 0xef, 2, "on the frame at " + x + "," + y)
                    ++on
                } else {
                    fuzzyCompare(grey(a), grey(b), 2, "off the frame at " + x + "," + y)
                    fuzzyCompare(Math.round(a.g * 255), Math.round(b.g * 255), 2)
                    ++off
                }
            }
            verify(on > 10 && off > 10)
        }
        function test_fit_pillarbox_reads_the_ground_beside_the_picture() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            fitCase(Qt.rect(70, 0, 60, 120))
        }
        function test_fit_letterbox_reads_the_ground_above_and_below_the_picture() {
            if (!gpu()) skip("ShaderEffect needs an RHI backend; use the command above")
            fitCase(Qt.rect(0, 30, 200, 60))
        }

        function test_a_window_without_a_ground_cannot_read() {
            verify(!Theme.readable(Theme.backdrop, bare), "it inverts instead")
            verify(Theme.readable(Theme.backdrop, scene.Window.window))
        }
    }
}
