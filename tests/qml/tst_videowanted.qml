import QtQuick
import QtTest
import "../../src/qml/components/videowanted.js" as VideoWanted

// Video is wanted only while a surface shows it: Now Playing with its toggle
// on, or the mini popup in video mode.
TestCase {
    name: "VideoWanted"

    function test_now_playing_with_the_toggle_on() {
        verify(VideoWanted.wanted(5, false, true, false, false, false))
        verify(!VideoWanted.wanted(5, false, false, false, false, false))   // toggle off
        verify(!VideoWanted.wanted(4, false, true, false, false, false))    // another view
        verify(!VideoWanted.wanted(5, true, true, false, false, false))     // mini mode hides the page
    }

    function test_expanding_from_mini_draws_the_page_with_its_video() {
        verify(VideoWanted.wanted(5, true, true, false, false, false, true))
        verify(!VideoWanted.wanted(5, true, false, false, false, false, true))   // toggle off
        verify(!VideoWanted.wanted(4, true, true, false, false, false, true))    // another view
    }

    function test_mini_popup_in_video_mode() {
        verify(VideoWanted.wanted(0, true, false, true, true, true))
        verify(!VideoWanted.wanted(0, true, false, true, true, false))      // visualiser chosen
        verify(!VideoWanted.wanted(0, true, false, false, true, true))      // popup shows the queue
        verify(!VideoWanted.wanted(0, true, false, true, false, true))      // popup closed
    }
}
