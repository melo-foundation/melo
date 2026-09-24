import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A slider, a toggle and a tab are themed. Each part is a role a theme can
// paint and a size it can set; the defaults are a 4px rail, a 12px knob and a
// 36×20 toggle.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_controls.qml
Item {
    width: 400; height: 200

    MSlider { id: sld; width: 150; from: 0; to: 100; value: 50 }
    MToggle { id: tog; y: 40 }
    MScrollBar { id: bar; x: 380; height: 100; size: 0.3; orientation: Qt.Vertical }
    SelectTab { id: tab; y: 80; label: "Library"; style: "button"; width: implicitWidth; height: Theme.btnH }

    TestCase {
        name: "Controls"
        when: windowShown

        function set(k, v) { Theme.ts[k] = v; Theme.tsChanged(); wait(20) }
        function unset(k) { delete Theme.ts[k]; Theme.tsChanged(); wait(20) }
        function part(item, name) {
            for (const c of item.children) if (c.objectName === name) return c
            return null
        }

        function cleanup() {
            for (const k of ["sliderTrackHeight", "sliderKnobSize", "sliderKnobShape", "sliderTrackShape", "sliderKnobInset", "scrollbars", "scrubberShape", "scrubberHover", "scrubberKnobSize", "scrubberKnobShape", "scrubberKnobInset",
                             "toggleWidth", "toggleHeight", "toggleKnobShape",
                             "controlScale", "buttonPress"]) delete Theme.ts[k]
            Theme.tsChanged(); wait(20)
        }

        function test_the_slider_is_the_sizes_it_always_had() {
            compare(part(sld, "sliderTrack").height, 4)
            compare(part(sld, "sliderFill").height, 4)
            compare(part(sld, "sliderKnob").width, 12)
            compare(part(sld, "sliderKnob").height, 12)
            compare(part(sld, "sliderKnob").radius, 6)
            // half the track is filled at the middle of the range
            compare(part(sld, "sliderFill").width, 75)
        }

        function test_the_slider_takes_its_sizes_from_the_theme() {
            set("sliderTrackHeight", 8)
            compare(part(sld, "sliderTrack").height, 8)
            compare(part(sld, "sliderFill").height, 8)
            set("sliderKnobSize", 20)
            compare(part(sld, "sliderKnob").width, 20)
            compare(part(sld, "sliderKnob").radius, 10)
            // pixels at ×1 control scale: the control size moves them
            set("controlScale", 2)
            compare(part(sld, "sliderTrack").height, 16)
            compare(part(sld, "sliderKnob").width, 40)
        }

        function test_a_square_knob_is_square() {
            compare(part(sld, "sliderKnob").radius, 6)
            set("sliderKnobShape", "square")
            compare(part(sld, "sliderKnob").radius, Theme.radiusSm)
            unset("sliderKnobShape")
            compare(part(sld, "sliderKnob").radius, 6)
        }

        function test_the_toggle_is_the_size_it_always_had() {
            compare(tog.width, 36); compare(tog.height, 20)
            const knob = part(tog, "toggleKnob")
            compare(knob.width, 16); compare(knob.height, 16)
            compare(knob.radius, 8)
            compare(knob.y, 2); tryCompare(knob, "x", 2)
        }

        function test_the_toggle_takes_its_size_and_shape_from_the_theme() {
            set("toggleWidth", 60); set("toggleHeight", 30)
            compare(tog.width, 60); compare(tog.height, 30)
            const knob = part(tog, "toggleKnob")
            compare(knob.width, 26, "the knob is the track less 2px a side")
            set("toggleKnobShape", "square")
            compare(knob.radius, Theme.radiusSm)
        }

        function test_the_track_squares_on_its_own_key() {
            compare(part(sld, "sliderTrack").radius, 2)
            set("sliderTrackShape", "square")
            compare(part(sld, "sliderTrack").radius, 0)
            compare(part(sld, "sliderFill").radius, 0)
            compare(part(sld, "sliderKnob").radius, 6, "the knob keeps its own shape")
        }

        function test_a_scrollbar_can_be_a_slider() {
            const thumb = part(bar.contentItem, "scrollThumb")
            compare(thumb.role, "scrollbar")
            verify(!bar.background.visible)
            fuzzyCompare(thumb.opacity, 0.35, 0.01)
            set("scrollbars", "slider"); set("sliderTrackHeight", 8); set("sliderKnobSize", 14)
            // A scrollbar has its own parts, which follow the slider's until
            // a theme gives them their own — a volume thumb cut as a small
            // capsule is not what a page-long scrollbar wants to be.
            compare(thumb.role, "scrollbarThumb")
            compare(bar.background.role, "scrollbarTrack"); verify(bar.background.visible)
            compare(Theme.roleColour("scrollbarThumb"), Theme.roleColour("sliderKnob"),
                    "and with none of its own it IS the slider's")
            compare(thumb.width, 14, "the thumb is the slider's knob")
            compare(bar.implicitWidth, 14 + 4, "the control is as thick as the wider part")
            compare(bar.background.width, 8, "the rail is the track, not the padded box")
            compare(bar.background.x, bar.leftPadding + 3, "centred in the knob's width")
            compare(Theme.scrollGutter, 2 + 14 + 2)
            tryCompare(thumb, "opacity", 1)
            // a knob narrower than the rail is still the knob's width
            set("sliderTrackHeight", 16); set("sliderKnobSize", 10)
            compare(thumb.width, 10, "not stretched to the rail")
            compare(thumb.x, 3, "centred in the rail's width")
            compare(bar.background.width, 16)
            set("sliderTrackShape", "square")
            compare(bar.background.radius, 0)
            set("sliderKnobShape", "square")
            compare(thumb.radius, Theme.radiusSm, "the thumb takes the knob's shape")
        }

        function test_the_knob_rests_where_the_theme_says() {
            const knob = part(sld, "sliderKnob"), fill = part(sld, "sliderFill")
            sld.value = 0
            compare(knob.x, 0, "unset: the knob just inside the rail")
            compare(fill.width, 6, "the fill ends under the knob's centre")
            set("sliderKnobInset", 0)
            compare(knob.x, -6, "0: its centre on the rail's end")
            compare(fill.width, 0)
            sld.value = 100
            compare(knob.x, 150 - 6)
            compare(fill.width, 150)
            set("sliderKnobInset", 10)
            compare(knob.x, 140 - 6)
            compare(fill.width, 140)
            compare(sld.valAt(140), 100); compare(sld.valAt(10), 0)
            compare(sld.valAt(75), 50)
            sld.value = 50
        }

        function test_a_scrollbar_keeps_the_theme_s_inset() {
            compare(bar.leftPadding, 2); compare(bar.implicitWidth, 8)
            compare(Theme.scrollGutter, 2, "the thin bar: the content clears only the gap")
            Theme.ts.insets = { scrollbar: { left: 5, right: 6, top: 1, bottom: 3 } }; Theme.tsChanged(); wait(20)
            compare(bar.leftPadding, 5); compare(bar.rightPadding, 6)
            compare(bar.topPadding, 1); compare(bar.bottomPadding, 3)
            compare(bar.implicitWidth, 4 + 11)
            compare(Theme.scrollGutter, 5)
            set("scrollbars", "slider"); set("sliderTrackHeight", 8); set("sliderKnobSize", 8)
            compare(Theme.scrollGutter, 5 + 8 + 6, "a slider: the gap, the wider part and its right inset")
            delete Theme.ts.insets; Theme.tsChanged(); wait(20)
        }

        function test_a_focused_slider_keeps_its_knob_colour() {
            const knob = part(sld, "sliderKnob")
            sld.forceActiveFocus()
            compare(knob.borderWidth, 0, "the ring is not on the knob")
            compare(knob.role, "sliderKnob")
            const ring = knob.children.find(c => c.borderRole === "sliderFill")
            verify(ring && ring.visible, "the ring sits around it, in the slider's fill")
        }

        function test_the_knob_travels_to_the_far_side_when_it_is_on() {
            const knob = part(tog, "toggleKnob")
            tryCompare(knob, "x", 2)
            tog.checked = true
            tryCompare(knob, "x", tog.width - knob.width - 2)   // it slides
            tog.checked = false
            wait(150)
        }

        // The roles are what a theme paints. A track is a button face, a
        // fill is the accent, and each follows until a theme says otherwise.
        function test_every_part_names_a_role() {
            compare(part(sld, "sliderTrack").role, "sliderTrack")
            compare(part(sld, "sliderFill").role, "sliderFill")
            compare(part(sld, "sliderKnob").role, "sliderKnob")
            compare(part(tog, "toggleKnob").role, "toggleKnob")
            compare(tog.role, "toggleOff")
            tog.checked = true; wait(20)
            compare(tog.role, "toggleOn")
            tog.checked = false; wait(20)
        }

        // A tab in the button style is a button: a framed face at rest, the
        // hover face under the pointer, the active face when it is chosen.
        function test_a_button_tab_takes_a_buttons_faces() {
            compare(tab.role, "button")
            compare(tab.borderWidth, 1)
            compare(tab.radius, Theme.radiusMd)
            tab.hover = true
            compare(tab.role, "buttonHover")
            compare(tab.borderRole, "borderStrong")
            tab.active = true
            // chosen already: the pointer changes neither face nor border
            compare(tab.role, "buttonActive")
            compare(tab.borderRole, "border")
            tab.hover = false
            compare(tab.role, "buttonActive")
            set("buttonPress", "face")
            tab.pressed = true
            compare(tab.role, "buttonPress", "held wins over active")
            tab.pressed = false; tab.active = false
        }

        // and the other styles are untouched by it
        function test_the_older_styles_frame_nothing() {
            for (const s of ["filled", "pill", "underline", "segment"]) {
                tab.style = s
                compare(tab.borderWidth, 0, s)
            }
            tab.style = "button"
        }
    }
}
