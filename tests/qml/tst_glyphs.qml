import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A theme may replace a glyph: `glyphs` is keyed by glyph name in the table's
// shape, and a name it lacks draws the built-in.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_glyphs.qml
Item {
    width: 200; height: 200

    Icon { id: played; name: "play"; color: "white"; size: 24 }
    Icon { id: paused; name: "pause"; color: "white"; size: 24 }

    TestCase {
        name: "Glyphs"
        when: windowShown

        // the plain Glyph is Icon's first child; the twin only exists for a
        // styled ink, and these two are drawn in a plain colour
        function glyphOf(icon) {
            for (const c of icon.children) if (c.spec !== undefined) return c
            return null
        }
        function set(v) { Theme.ts.glyphs = v; Theme.tsChanged(); wait(20) }
        function cleanup() { delete Theme.ts.glyphs; Theme.tsChanged(); wait(20) }

        function test_a_name_the_theme_does_not_carry_draws_the_built_in() {
            compare(Theme.glyphOf("play").paths, Theme.glyphDefaults.play.paths)
            compare(glyphOf(played).spec.paths[0], "M6 3.5L20 12L6 20.5V3.5Z")
        }

        function test_an_override_draws_its_own_paths() {
            set({ play: { vb: 10, ink: 10, fill: false, sw: 1.5, paths: ["M0 0L10 10", "M0 10L10 0"] } })
            const e = Theme.glyphOf("play")
            compare(e.vb, 10)
            compare(e.fill, false)
            const g = glyphOf(played)
            compare(g.spec.paths, ["M0 0L10 10", "M0 10L10 0"])
            compare(g.vb, 10)
            compare(g.swRaw, 1.5)
            // and the one it did not name is still the built-in
            compare(glyphOf(paused).spec.paths, Theme.glyphDefaults.pause.paths)
        }

        function test_the_override_is_dropped_again() {
            set({ play: { vb: 10, fill: true, paths: ["M0 0H10V10H0Z"] } })
            compare(glyphOf(played).spec.paths[0], "M0 0H10V10H0Z")
            set({})
            compare(glyphOf(played).spec.paths[0], "M6 3.5L20 12L6 20.5V3.5Z")
        }
    }
}
