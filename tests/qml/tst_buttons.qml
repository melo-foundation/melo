import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"
import "../../src/qml/components/barstyles"

// Every button takes the theme's button height, faceOf()'s faces and its sink.
// An off button reacts to nothing, since a lit face promises a click; the
// primary keeps its accent while held; an on button, already picked, does not
// hover.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_buttons.qml
Item {
    width: 500; height: 240

    PushButton { id: plain; label: "Save" }
    PushButton { id: off;   y: 50; label: "Save"; enabled: false }
    PushButton { id: prim;  y: 100; label: "OK"; accent: true }
    PushButton { id: chosen; x: 200; label: "Grid"; active: true }
    PushButton { id: del; x: 200; y: 50; label: "Delete"; danger: true }
    // no PlayerState in the test runner, so this one has no track: disabled
    TransportButton { id: tb; y: 150; which: "play" }
    TransportButton { id: pill; x: 60; y: 150; which: "prev"; disc: true; pillW: 35; pillH: 13
                      width: implicitWidth; height: implicitHeight }
    // a tab strip in the button style, a dropdown's head, a bare icon that is on
    SelectTab { id: tab; objectName: "tab1"; x: 300; y: 0; label: "Library"; style: "button"; width: implicitWidth; height: Theme.btnH
                hover: tabMa.containsMouse; pressed: tabMa.pressed
                MouseArea { id: tabMa; anchors.fill: parent; hoverEnabled: true } }
    Item { id: fakeMenu; property bool visible_: false; property Item owner: null; visible: visible_ }
    SelectHead { id: head; x: 300; y: 60; label: "Pick"; menu: fakeMenu }
    IconButton { id: pin; x: 300; y: 120; name: "pin"; active: true }
    IconButton { id: pinFramed; x: 350; y: 120; name: "pin"; active: true; framed: true }

    TestCase {
        name: "Buttons"
        when: windowShown

        function set(k, v) { Theme.ts[k] = v; Theme.tsChanged(); wait(20) }
        function cleanup() {
            for (const k of ["buttonPress", "buttonHeight", "controlScale", "transportButtons"])
                delete Theme.ts[k]
            Theme.tsChanged(); wait(20)
        }
        function find(item, name) {
            for (const c of item.children) {
                if (c.objectName === name) return c
                const deep = find(c, name)
                if (deep !== null) return deep
            }
            return null
        }
        function labelOffset(btn) { return find(btn, "btnLabel").anchors.horizontalCenterOffset }

        // ---- the size ----
        function test_a_button_is_the_height_the_theme_gives_buttons() {
            compare(plain.height, Theme.btnH)
            compare(Theme.btnH, 22)     // the default
            set("buttonHeight", 30)
            compare(Theme.btnH, 30)
            compare(plain.height, 30)
            compare(prim.height, 30)
            // pixels at ×1 control scale, like everything clickable
            set("controlScale", 2)
            compare(plain.height, 60)
        }

        // ---- the press ----
        function test_a_held_button_takes_the_press_face_and_sinks() {
            set("buttonPress", "sink")
            compare(plain.role, "button")
            compare(labelOffset(plain), 0)
            mousePress(plain, plain.width / 2, plain.height / 2)
            wait(20)
            compare(plain.held, true)
            compare(plain.role, "buttonPress")
            compare(labelOffset(plain), 1)
            mouseRelease(plain, plain.width / 2, plain.height / 2)
            wait(20)
            compare(plain.held, false)
            compare(labelOffset(plain), 0)
        }

        // ---- off means off ----
        function test_a_disabled_button_takes_no_face_and_does_not_sink() {
            set("buttonPress", "sink")
            mouseMove(off, off.width / 2, off.height / 2)
            wait(20)
            compare(off.hovered, false)
            compare(off.role, "button")
            mousePress(off, off.width / 2, off.height / 2)
            wait(20)
            compare(off.held, false)
            compare(off.role, "button", "a disabled button must not take the press face")
            compare(labelOffset(off), 0, "a disabled button must not sink")
            mouseRelease(off, off.width / 2, off.height / 2)
            wait(20)
        }

        // ---- the primary one ----
        function test_the_accent_keeps_its_colour_while_it_is_held() {
            set("buttonPress", "sink")
            mousePress(prim, prim.width / 2, prim.height / 2)
            wait(20)
            compare(prim.held, true)
            verify(prim.role === "accent" || prim.role === "accentHover")
            compare(labelOffset(prim), 1, "the accent still sinks")
            mouseRelease(prim, prim.width / 2, prim.height / 2)
            wait(20)
            compare(labelOffset(prim), 0)
        }

        // ---- on is already the answer ----
        function test_an_active_button_does_not_hover() {
            compare(chosen.role, "buttonActive")
            compare(chosen.borderRole, "border")
            mouseMove(chosen, chosen.width / 2, chosen.height / 2)
            wait(20)
            compare(chosen.hovered, true, "the pointer is on it")
            compare(chosen.role, "buttonActive", "the chosen one does not light up")
            compare(chosen.borderRole, "border", "nor does its edge")
            // and it still sinks, because a press is what the hand is doing now
            set("buttonPress", "sink")
            mousePress(chosen, chosen.width / 2, chosen.height / 2)
            wait(20)
            compare(chosen.role, "buttonPress")
            compare(labelOffset(chosen), 1)
            mouseRelease(chosen, chosen.width / 2, chosen.height / 2)
            wait(20)
            compare(chosen.role, "buttonActive")
            // park the pointer off it again for the tests that follow
            mouseMove(plain, -50, -50)
            wait(20)
        }

        // ---- a danger button's label is the danger colour ----
        function test_a_danger_button_takes_the_danger_colour() {
            compare(find(del, "btnLabel").color, Theme.danger)
            compare(del.role, "button", "the face is a button's")
            compare(find(plain, "btnLabel").color, Theme.text)
        }

        // ---- a tab drawn as a button is a button ----
        function test_a_tab_in_the_button_style_takes_the_press() {
            set("buttonPress", "sink")
            compare(tab.role, "button")
            mousePress(tab, tab.width / 2, tab.height / 2); wait(20)
            compare(tab.role, "buttonPress", "held, it takes the press face")
            compare(tab.pressed, true)
            mouseRelease(tab, tab.width / 2, tab.height / 2); wait(20)
            mouseMove(plain, -50, -50); wait(20)
        }

        // ---- a dropdown's head is active while its list shows ----
        function test_a_dropdown_head_is_active_while_its_menu_is_open() {
            compare(find(head, "selFace").role, "button")
            fakeMenu.owner = head; fakeMenu.visible_ = true; wait(20)
            compare(find(head, "selFace").role, "buttonActive")
            compare(find(head, "selFace").borderRole, "border")
            fakeMenu.owner = null; wait(20)
            compare(find(head, "selFace").role, "button", "another head's menu is not this one's")
            fakeMenu.visible_ = false
        }

        // ---- an icon that is on: the active face when framed, nothing bare ----
        function test_an_active_icon_takes_the_active_face_only_when_framed() {
            compare(find(pin, "iconFace").visible, false, "bare: the glyph alone says it")
            compare(find(pinFramed, "iconFace").visible, true)
            compare(find(pinFramed, "iconFace").role, "buttonActive")
            compare(find(pinFramed, "iconFace").borderRole, "border")
        }

        // ---- the transport with nothing to play ----
        function test_a_transport_with_no_track_does_not_react() {
            set("transportButtons", "button")
            set("buttonPress", "sink")
            compare(tb.enabled_, false)
            const face = find(tb, "iconFace")
            const glyph = find(tb, "iconGlyph")
            verify(face !== null && glyph !== null)
            const rest = glyph.mapToItem(tb, glyph.width / 2, glyph.height / 2)
            mousePress(tb, tb.width / 2, tb.height / 2)
            wait(20)
            // its MouseArea IS pressed — the click is guarded inside — and the
            // face and the glyph must ignore that
            compare(tb.held, false)
            compare(face.role, "button", "a transport with no track must not take the press face")
            const held = glyph.mapToItem(tb, glyph.width / 2, glyph.height / 2)
            compare(Math.round(held.x), Math.round(rest.x))
            compare(Math.round(held.y), Math.round(rest.y))
            mouseRelease(tb, tb.width / 2, tb.height / 2)
            wait(20)
        }

        // ---- a transport as a pill ----
        // `w` and `h` give a transport a silhouette of its own; the disc under
        // it rounds to the shorter side, so 35 x 13 is a capsule, not a circle
        function test_a_transport_with_a_width_and_height_is_a_pill() {
            compare(pill.implicitWidth, 35)
            compare(pill.implicitHeight, 13)
            compare(pill.children[0].radius, 6.5)
            // without them a disc stays as wide as it is tall
            compare(tb.implicitWidth, tb.implicitHeight)
        }
    }
}
