import QtQuick
import QtTest
import "../../src/qml/components/onboarding.js" as Onboarding

// First run's own decisions. The rows are the app's existing controls and
// lists; what is decided here is which mood names to offer as new profiles,
// and how the crossfade reads.
TestCase {
    name: "Onboarding"

    function test_three_mood_names_are_offered_to_a_new_user() {
        compare(Onboarding.moodSuggestions([]).length, 3)
    }

    function test_a_name_already_taken_is_not_offered_again() {
        const got = Onboarding.moodSuggestions(["Default", "focus"])
        verify(got.indexOf("Focus") < 0, "Focus offered though focus exists")
        compare(got.length, 3)
    }

    function test_suggestions_run_out_rather_than_repeat() {
        const taken = ["Focus", "Chill", "Gym", "Sleep", "Party", "Study"]
        const left = Onboarding.moodSuggestions(taken)
        compare(left, [])
    }

    function test_crossfade_reads_off_at_zero_and_seconds_otherwise() {
        compare(Onboarding.crossfadeLabel(0), "Off")
        compare(Onboarding.crossfadeLabel(2.5), "2.5s")
        compare(Onboarding.crossfadeLabel(12), "12.0s")
    }
}
