import QtQuick
import QtTest
import "../../src/qml/components/nowplaying/sleeve.js" as Sleeve

// Over video the sleeve is glass on the poster face and solid before the
// record inside it can show.
TestCase {
    name: "SleeveCover"

    function test_solid_before_record_shows() {
        for (let i = 0; i <= 100; i++) {
            const p = i / 100
            if (Sleeve.emerge(p, 0) > 0.001)
                compare(Sleeve.cover(p, 1), 1, "p " + p)
        }
    }

    function test_glass_on_poster() {
        compare(Sleeve.cover(0, 1), 0)
        verify(Sleeve.cover(0.25, 1) > 0 && Sleeve.cover(0.25, 1) < 1)
    }

    function test_opaque_without_video() {
        compare(Sleeve.cover(0, 0), 1)
        compare(Sleeve.cover(0.3, 0), 1)
    }
}
