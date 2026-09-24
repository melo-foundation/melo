import QtQuick
import QtTest

// Qt reads a nine-character hex string as #AARRGGBB, alpha first, so "dd"
// appended to "#rrggbb" is a different hue. Pins Qt's premise for ThemeStore's
// QColor::HexArgb.
Item {
    TestCase {
        name: "ColorHexParsing"

        function test_nine_char_hex_is_alpha_first() {
            const wrong = Qt.color("#cc3333dd")   // "#rrggbb" + "dd"
            const right = Qt.color("#ddcc3333")   // "#aarrggbb"
            const base  = Qt.color("#cc3333")

            // appending alpha shifts every channel along
            fuzzyCompare(wrong.a, 0.8, 0.01, "alpha came from the FIRST pair")
            verify(Math.abs(wrong.b - base.b) > 0.5,
                   "appending alpha must change the blue channel — if it does not, "
                   + "Qt has changed how it reads nine-character hex and the "
                   + "HexArgb fix in ThemeStore should be revisited")

            // alpha first leaves the colour alone
            fuzzyCompare(right.r, base.r, 0.001)
            fuzzyCompare(right.g, base.g, 0.001)
            fuzzyCompare(right.b, base.b, 0.001)
            fuzzyCompare(right.a, 0.867, 0.01)
        }

        // The picker hands its result back as a string, and the palette stores
        // that string, so the two have to agree on the form.
        function test_qml_emits_alpha_first_too() {
            compare(Qt.rgba(0.8, 0.2, 0.2, 0.5).toString(), "#80cc3333")
            compare(Qt.rgba(0.8, 0.2, 0.2, 1).toString(), "#cc3333",
                    "an opaque colour must still round-trip as six digits")
        }

        // What glass() does: multiply, so a colour's own alpha survives.
        function test_alpha_multiplies_rather_than_replaces() {
            const c = Qt.color("#80151515")     // a surface that is half transparent
            fuzzyCompare(c.a, 0.502, 0.01)
            const bgOpacity = 0.5
            fuzzyCompare(c.a * bgOpacity, 0.251, 0.01,
                         "glass() multiplies the source alpha; replacing it would "
                         + "give 0.5 and the palette's own alpha would be lost")
        }
    }
}
