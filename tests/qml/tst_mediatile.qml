import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A card's edge can be the point of it. A bevelled card is a bevel around a
// picture, unless the picture covers the bevel, so the picture and the text
// can each be kept inside the card's edge band.
Item {
    width: 400; height: 400
    MediaTile { id: tile; width: 160; title_: "A title"; meta_: "meta" }
    TestCase {
        name: "MediaTile"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() { Theme.held = false }
        function cleanup() { delete Theme.ts.insets; delete Theme.ts.cardArtCorners; delete Theme.ts.cardArtInset; Theme.tsChanged() }
        // one number a side: art all round, text left/right/bottom
        function set(art, text) {
            const ins = {}
            if (art !== undefined) ins.cardArt = art
            if (text !== undefined) ins.cardText = ({ left: text, top: 0, right: text, bottom: text })
            Theme.ts.insets = ins; Theme.tsChanged(); wait(20)
        }
        function thumb() { for (const c of tile.children) if (c.shimmer !== undefined) return c; return null }
        function textBlock() { for (const c of tile.children) if (c.tscale !== undefined) return c; return null }

        function test_the_playing_card_has_its_own_face_and_no_hover() {
            function ground() { for (const c of tile.children) if (c.role !== undefined) return c; return null }
            compare(ground().role, "card")
            tile.selected = true
            compare(ground().role, "cardSelected")
            mouseMove(tile, 10, 10); wait(30)
            compare(ground().role, "cardSelected", "no hover face over the chosen one")
            tile.selected = false
            mouseMove(tile, 300, 300)
        }

        function test_the_picture_fills_the_top_by_default() {
            set(undefined, undefined)
            compare(Theme.cardInset("cardArt", "left"), 0)
            compare(thumb().x, 0); compare(thumb().y, 0)
            compare(thumb().width, tile.width)
            compare(thumb().bottomRadius, 0)
        }
        function test_inset_art_keeps_the_edge_clear() {
            set(8, 0)
            const t = thumb()
            fuzzyCompare(t.x, 8 * tile.unit, 0.01)
            fuzzyCompare(t.y, 8 * tile.unit, 0.01)
            fuzzyCompare(t.width, tile.width - 16 * tile.unit, 0.01)
            verify(t.height < Math.floor(tile.width * 9 / 16), "narrower, so shorter")
            compare(t.bottomRadius, t.radius, "inside the card, all four corners")
        }
        // From the left, the right and the bottom; the top is the picture
        function test_the_texts_inset_is_three_sided() {
            set(8, 12)
            const t = thumb(), b = textBlock()
            fuzzyCompare(b.y, t.y + t.height, 0.01, "starts under the picture")
            fuzzyCompare(b.x, 12 * tile.unit, 0.01)
            fuzzyCompare(b.width * b.scale, tile.width - 24 * tile.unit, 0.01)
            fuzzyCompare(b.y + b.height * b.scale, tile.height - 12 * tile.unit, 0.01)
        }
        function test_the_default_is_what_a_card_always_was() {
            set(0, undefined)
            compare(Theme.cardInset("cardText", "left"), 8)
            const t = thumb(), b = textBlock()
            compare(b.y, t.height)
            fuzzyCompare(b.x, 8 * tile.unit, 0.01)
            fuzzyCompare(b.width * b.scale, 144 * tile.unit, 0.01)
        }
        function test_no_inset_reaches_the_edges() {
            set(0, 0)
            const b = textBlock()
            compare(b.x, 0)
            fuzzyCompare(b.width * b.scale, tile.width, 0.01)
            fuzzyCompare(b.y + b.height * b.scale, tile.height, 0.01)
        }
        function test_the_corners_can_be_named() {
            set(8, 0)
            Theme.ts.cardArtCorners = "square"; Theme.tsChanged(); wait(20)
            compare(thumb().radius, 0)
            Theme.ts.cardArtCorners = "round"; Theme.tsChanged(); wait(20)
            compare(thumb().radius, Theme.radiusLg)
        }
        // the legacy single-number key still reads
        function test_the_old_key_still_reads() {
            Theme.ts.cardArtInset = 8; Theme.tsChanged(); wait(20)
            compare(Theme.cardInset("cardArt", "left"), 8)
            fuzzyCompare(thumb().x, 8 * tile.unit, 0.01)
        }
        // And four sides: the picture's top and the text's top are their own
        function test_each_side_is_its_own() {
            Theme.ts.insets = ({ cardArt: { left: 4, top: 10, right: 2, bottom: 0 }, cardText: { left: 3, top: 5, right: 7, bottom: 9 } })
            Theme.tsChanged(); wait(20)
            const t = thumb(), b = textBlock()
            fuzzyCompare(t.x, 4 * tile.unit, 0.01); fuzzyCompare(t.y, 10 * tile.unit, 0.01)
            fuzzyCompare(t.width, tile.width - 6 * tile.unit, 0.01)
            fuzzyCompare(b.x, 3 * tile.unit, 0.01)
            fuzzyCompare(b.y, t.y + t.height + 5 * tile.unit, 0.01)
            fuzzyCompare(b.width * b.scale, tile.width - 10 * tile.unit, 0.01)
            fuzzyCompare(b.y + b.height * b.scale, tile.height - 9 * tile.unit, 0.01)
        }
    }
}
