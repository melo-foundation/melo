import QtQuick
import QtTest
import "../../src/qml/components"

// Skeleton transition contract: showing the skeleton is INSTANT (any fade-in
// reads as a blank dip over just-cleared content); leaving it morphs — width
// animates to the text's width under a cross-fade. Guards the Behavior
// evaluation-order race that made show/hide animation nondeterministic.
Item {
    width: 400; height: 100

    SkeletonText {
        id: st
        x: 10; y: 10; width: 300
        text: "An example track title"
        color: "white"
        loading: true
        placeholderWidth: 120
        font.pixelSize: 13
    }

    TestCase {
        name: "SkeletonTextTransitions"
        when: windowShown

        function test_a_initial_loading_is_fully_shown() {
            compare(st.barOpacity, 1.0)
            compare(st.labelOpacity, 0.0)
            compare(st.barWidth, 120)
        }

        function test_b_leaving_loading_morphs() {
            st.loading = false
            wait(80)
            // SEQUENCED: width stretches toward the measured text FIRST,
            // at full bar opacity — the dissolve only starts after
            verify(st.barWidth !== 120, "width morphing: " + st.barWidth)
            compare(st.barOpacity, 1.0)
            tryVerify(() => st.barOpacity > 0.0 && st.barOpacity < 1.0, 1000,
                      "then dissolves")
            tryVerify(() => st.barOpacity === 0.0, 1000, "bar fully gone")
            compare(st.labelOpacity, 1.0)
            // the bar landed at the TEXT's width, not the placeholder's and
            // not the empty-text ~1px (the shrink-into-itself bug)
            verify(Math.abs(st.barWidth - st.implicitWidth) < 2,
                   "bar ended at text width: " + st.barWidth + " vs " + st.implicitWidth)
        }

        function test_c_entering_loading_is_instant() {
            st.loading = true
            // NO wait: must be fully shown synchronously after the state change
            compare(st.barOpacity, 1.0)
            compare(st.labelOpacity, 0.0)
            compare(st.barWidth, 120)
        }
    }
}
