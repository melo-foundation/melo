import QtQuick
import QtQuick.Window
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// Registered twice: at the default scale and at QT_SCALE_FACTOR=2.
Item {
    id: scene
    width: 200; height: 120
    StyledFill { id: fill; width: 120; height: 72; local: true; kind: "image" }
    ImageFillSettings {
        id: settings
        y: 80; width: 200
        picker: QtObject {
            property string stSrc: ""
            property string layerSpace: ""
            function optionOf(name) { return name === "fit" ? 5 : name.startsWith("slice") ? 255 : 0 }
            function setOption(name, value) {}
            function livePreview() {}
        }
    }
    TestCase {
        name: "ImageFillsDpr"; when: windowShown
        readonly property string grid: Qt.resolvedUrl("data/image-grid.svg").toString()
        readonly property string ramp: Qt.resolvedUrl("data/image-ramp.png").toString()
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function setImage(src, fit) {
            fill.layers = Theme.layersOf({ colour: "#ffffff", source: "image",
                params: { src: src, speed: 0, scale: 1, angle: 0, own: { fit: fit } } })
            const layer = findChild(fill, "fillLayer_0")
            tryVerify(() => layer.picture !== null && layer.picture.status === Image.Ready
                            && String(layer.picture.source) === src)
            return layer
        }
        function test_svg_reports_its_size_in_logical_pixels_data() {
            return [0, 1, 2, 3, 4, 5, 0, 4].map((fit, i) => ({ tag: i + ": fit " + fit, fit: fit }))
        }
        function test_svg_reports_its_size_in_logical_pixels(data) {
            const layer = setImage(grid, data.fit)
            fuzzyCompare(layer.geo1.w, 18 / 24, 0.002)
            if (data.fit >= 4) {
                compare(layer.imageGeometry.x, 24)
                compare(layer.imageGeometry.y, 18)
            }
        }
        // the picture delegate is kept, so its source changes under it
        function test_svg_after_a_raster_in_the_same_layer() {
            setImage(ramp, 4)
            const layer = setImage(grid, 4)
            compare(layer.imageGeometry.x, 24)
            compare(layer.imageGeometry.y, 18)
        }
        // oversized cuts are clamped to one pixel short of the picture
        function test_slice_preview_clamps_to_the_svg_size() {
            const preview = findChild(settings, "imagePlacementPreview")
            for (const src of [ramp, grid]) settings.picker.stSrc = src
            tryVerify(() => preview.cutsX[0] + preview.cutsX[1] > 0)
            fuzzyCompare(preview.cutsX[0] + preview.cutsX[1], 23, 0.001)
            fuzzyCompare(preview.cutsY[0] + preview.cutsY[1], 17, 0.001)
        }
    }
}
