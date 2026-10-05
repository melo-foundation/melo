import QtQuick
import QtTest
import "../../src/qml/components/overlay.js" as Overlay

// The words, pills and cursor over the video clear on idle or on a forced
// hide, only while the video shows on the poster face; a neutral click flips
// what is shown.
TestCase {
    name: "OverlayToggle"

    function test_clear() {
        verify(Overlay.clear(true, true, true, false))      // idle
        verify(Overlay.clear(true, true, false, true))      // forced
        verify(!Overlay.clear(true, true, false, false))    // active, not forced
        verify(!Overlay.clear(false, true, true, true))     // no video
        verify(!Overlay.clear(true, false, true, true))     // off the poster
    }

    function test_after_click() {
        compare(Overlay.afterClick(true), false)    // hidden: show
        compare(Overlay.afterClick(false), true)    // shown: hide
    }
}
