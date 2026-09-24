import QtQuick
import QtTest
import "../../src/qml/components/barswap.js" as Swap

// The ground and the rows start together. A swap waits for its incoming
// renderer to have been drawn; if the ground does not wait with it, the bar's
// card changes shape around the rows it is replacing.
TestCase {
    name: "BarSwap"

    function test_no_transition_lands_at_once() {
        compare(Swap.backingAction("none", false, false), "snap")
        compare(Swap.backingAction("none", false, true), "snap")
    }

    function test_a_bar_behind_the_flip_lands_at_once() {
        // quiet: the mini toggle puts the hidden bar on the outgoing layout
        // first; that step must not animate, or the flip reveals a bar already
        // in motion
        compare(Swap.backingAction("rise", true, false), "snap")
        compare(Swap.backingAction("rise", true, true), "snap")
    }

    function test_the_ground_waits_for_a_swap_that_is_waiting() {
        compare(Swap.backingAction("rise", false, true), "hold")
        compare(Swap.backingAction("blur", false, true), "hold")
        compare(Swap.backingAction("height", false, true), "hold")
    }

    function test_and_plays_at_once_when_nothing_is_waiting() {
        compare(Swap.backingAction("rise", false, false), "play")
        compare(Swap.backingAction("fade", false, false), "play")
    }

    // The ground arrives with the rows it belongs to.
    function test_the_ground_does_not_move_while_the_swap_is_waiting() {
        // A swap holds at 0 until the incoming renderer has been drawn, so the
        // incoming rows are not on screen at all — morphIn is 0. A ground on a
        // clock of its own crossfades through that wait and puts the new card
        // around the OLD rows, for as long as the build takes.
        compare(Swap.groundProgress(true, 0.0, 0.25), 0.0)
        compare(Swap.groundProgress(true, 0.0, 0.60), 0.0)
        compare(Swap.groundProgress(true, 0.0, 1.00), 0.0)
    }

    function test_and_then_arrives_exactly_with_them() {
        for (const t of [0.0, 0.25, 0.5, 0.75, 1.0])
            compare(Swap.groundProgress(true, t, 1.0), t)
    }

    // The bar is as tall as the rows it is showing.
    function test_the_bar_keeps_its_height_while_the_swap_is_waiting() {
        // waiting: the incoming rows are not on screen, so the bar must still
        // be the height of what IS on screen — not easing towards a layout
        // nobody can see yet
        compare(Swap.barHeight(true, 56, 0.0, 96), 56)
        compare(Swap.barHeight(true, 96, 0.0, 56), 96)
    }
    function test_and_then_eases_to_the_new_one() {
        // once the rows begin arriving it is the settled height, and the
        // Behavior on it does the easing the theme asked for
        compare(Swap.barHeight(true, 56, 0.01, 96), 96)
        compare(Swap.barHeight(true, 56, 1.0, 96), 96)
    }
    function test_no_swap_means_the_settled_height() {
        compare(Swap.barHeight(false, 56, 0.0, 77), 77)
        // a swap with no height captured (same/morph) is left alone
        compare(Swap.barHeight(true, 0, 0.0, 77), 77)
    }

    function test_a_backing_changed_by_itself_runs_its_own_animation() {
        compare(Swap.groundProgress(false, 0.0, 0.35), 0.35)
        compare(Swap.groundProgress(false, 1.0, 0.60), 0.60)
    }
}
