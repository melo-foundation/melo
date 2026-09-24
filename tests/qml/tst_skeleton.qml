import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A skeleton is the skeleton role (a Rectangle in its colour, a Surface
// under it once the role has a fill) in the theme's style: a shimmer sweeps
// a sheen across it, a pulse breathes it, still is still.
// Run: QT_QPA_PLATFORM=offscreen qmltestrunner-qt6 -input tests/qml/tst_skeleton.qml
Item {
    width: 300; height: 200
    Skeleton { id: sk; width: 160; height: 90 }
    Skeleton { id: plain; y: 100; width: 160; height: 40; shimmer: false }

    TestCase {
        name: "Skeleton"
        when: windowShown
        function set(k, v) { Theme.ts[k] = v; Theme.tsChanged(); wait(20) }
        function cleanup() { delete Theme.ts.skeletonStyle; Theme.tsChanged(); wait(20) }
        function part(item, name) { for (const c of item.children) if (c.objectName === name) return c; return null }
        function sheen(item) { return part(item, "skeletonGround").gradient != null }   // unset reads undefined
        function fill(item) { const f = part(part(item, "skeletonGround"), "skeletonFill"); return f && f.item !== undefined ? f.item : f }

        function test_the_ground_is_the_skeleton_role() {
            compare(part(sk, "skeletonGround").topLeftRadius, Theme.radiusSm)
            compare(part(sk, "skeletonGround").color, Theme.skeleton)
            compare(fill(sk), null, "a flat role is the Rectangle alone")
        }
        function test_a_role_with_a_fill_gets_a_surface() {
            Theme.p.skeleton = ({ colour: "#3873a8", source: "bevel" })
            Theme.pChanged(); wait(20)
            verify(fill(sk) !== null, "a fill loads a Surface")
            compare(fill(sk).role, "skeleton")
            compare(fill(sk).topLeftRadius, Theme.radiusSm)
            compare(part(sk, "skeletonGround").color, Qt.rgba(0, 0, 0, 0), "the ground shows the Surface through")
            verify(sheen(sk), "the sheen still sweeps over it")
            delete Theme.p.skeleton
            Theme.pChanged(); wait(20)
            compare(fill(sk), null, "gone with the fill")
        }
        // The artwork container stays visible for ever and is covered by the
        // picture, so tying the fill's life to `needed` would destroy and
        // rebuild a whole Surface chain on every card, every pass over the feed.
        function test_a_covered_skeleton_keeps_its_fill_and_stops_drawing() {
            Theme.p.skeleton = ({ colour: "#3873a8", source: "bevel" })
            Theme.pChanged(); wait(20)
            const loader = part(part(sk, "skeletonGround"), "skeletonFill")
            verify(loader.item !== null, "a fill loads a Surface")
            verify(loader.visible, "and draws while the skeleton is needed")
            sk.needed = false; wait(20)
            verify(loader.item !== null, "the picture covering it does not tear it down")
            verify(!loader.visible, "it just stops drawing")
            // a picture that is missing for a frame or two (a recycled card's
            // image decoding) does not bring the placeholder back
            sk.needed = true; wait(20)
            verify(!loader.visible, "a blink of need does not draw it")
            sk.needed = false; wait(150)
            verify(!loader.visible, "and it is still hidden once the picture is back")
            sk.needed = true
            tryVerify(() => loader.visible, 1000, "and draws again when it stays needed")
            // a refresh: the card is loading again, so it shows at once
            sk.needed = false; wait(20)
            sk.loading = true; sk.needed = true; wait(20)
            verify(loader.visible, "a loading card draws its placeholder immediately")
            sk.needed = false; sk.loading = false; wait(20)
            sk.needed = true; sk.loading = true; wait(20)
            verify(loader.visible, "whichever of needed and loading changes first")
            sk.loading = false
            delete Theme.p.skeleton
            Theme.pChanged(); wait(20)
        }
        function test_shimmer_sweeps_a_sheen() {
            compare(Theme.skeletonStyle, "shimmer")
            verify(sheen(sk))
            const p0 = sk.sheenPos
            wait(200)
            verify(sk.sheenPos !== p0, "the sheen moves")
            compare(part(sk, "skeletonGround").opacity, 1)
        }
        function test_pulse_breathes_the_ground_and_sweeps_nothing() {
            set("skeletonStyle", "pulse")
            verify(!sheen(sk))
            wait(300)
            verify(part(sk, "skeletonGround").opacity < 1, "the ground dims")
        }
        function test_still_is_still() {
            set("skeletonStyle", "still")
            verify(!sheen(sk))
            const p0 = sk.sheenPos
            wait(200)
            compare(sk.sheenPos, p0)
            compare(part(sk, "skeletonGround").opacity, 1)
        }
        function test_a_plain_container_never_animates() {
            verify(!sheen(plain))
            wait(100)
            compare(part(plain, "skeletonGround").opacity, 1)
        }
    }
}
