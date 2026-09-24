import QtQuick
import QtTest
import "../../src/qml/components/barkeys.js" as Keys

// What a bar cell is called. The renderer tells an edit from a replacement
// with these, and the arranger addresses the cell it is editing with them, so
// the two must agree — a cell keyed one way and picked another can only be
// reached by where it happens to sit.
TestCase {
    name: "BarKeys"

    function test_a_cells_key_is_its_kind_not_its_document() {
        // the same cell through an edit
        compare(Keys.cellKey({ type: "thumb", w: 48, h: 28 }),
                Keys.cellKey({ type: "thumb", w: 64, h: 37 }))
        compare(Keys.cellKey({ type: "title", lines: 2 }),
                Keys.cellKey({ type: "title", lines: 1 }))
        // different kinds are different cells
        verify(Keys.cellKey({ type: "elapsed" }) !== Keys.cellKey({ type: "total" }))
    }

    function test_a_button_is_named_by_its_command() {
        compare(Keys.cellKey({ type: "button", id: "eq" }), "button:eq")
        verify(Keys.cellKey({ type: "button", id: "eq" }) !== Keys.cellKey({ type: "button", id: "queue" }))
        // a size knob does not rename it
        compare(Keys.cellKey({ type: "button", id: "eq" }),
                Keys.cellKey({ type: "button", id: "eq", size: 24 }))
    }

    function test_a_spacer_is_its_width_and_copies_are_numbered_apart() {
        const cells = [ { type: "spacer", w: 16 }, { type: "button", id: "eq" },
                        { type: "spacer", w: 16 }, { type: "spacer", w: 8 } ]
        const k = Keys.cellKeys(cells)
        compare(k.length, 4)
        verify(k[0] !== k[2])              // two of one width, told apart
        compare(k[2], k[0] + "#2")
        verify(k[3] !== k[0] && k[3] !== k[2])
        // every key in a row is unique, which is what the diff relies on
        compare((new Set(k)).size, 4)
    }

    function test_the_drag_marker_never_renames_a_cell() {
        compare(Keys.cellKey({ type: "spacer", w: 16 }),
                Keys.cellKey({ type: "spacer", w: 16, _drag: true }))
    }

    function test_the_disc_is_one_element_but_two_cells() {
        compare(Keys.elementKey({ type: "playdisc" }), Keys.elementKey({ type: "play" }))
        // a title without its artist is its own shelf element
        verify(Keys.elementKey({ type: "title", artist: "none" }) !== Keys.elementKey({ type: "title" }))
        compare(Keys.elementKey({ type: "title", artist: "inline" }), Keys.elementKey({ type: "title" }))
        verify(Keys.cellKey({ type: "playdisc" }) !== Keys.cellKey({ type: "play" }))
    }

    function test_a_pick_round_trips_even_through_a_comma() {
        const p = Keys.cellPick(1, "button:eq")
        verify(Keys.isCell(p)); verify(!Keys.isRow(p))
        compare(Keys.pickRow(p), 1); compare(Keys.pickKey(p), "button:eq")
        // a spacer's key is a document and holds commas, so a comma cannot
        // tell a cell pick from a row pick
        const sk = Keys.cellKey({ type: "spacer", w: 16, gap: 4 })
        verify(sk.indexOf(",") >= 0)
        const sp = Keys.cellPick(0, sk)
        verify(Keys.isCell(sp)); verify(!Keys.isRow(sp))
        compare(Keys.pickRow(sp), 0); compare(Keys.pickKey(sp), sk)
        const r = Keys.rowPick(2)
        verify(Keys.isRow(r)); verify(!Keys.isCell(r))
        compare(Keys.pickRow(r), 2)
    }

    function test_a_selection_survives_a_reorder() {
        const before = [ { type: "thumb" }, { type: "title" }, { type: "button", id: "eq" } ]
        const key = Keys.cellKeys(before)[2]
        compare(Keys.indexOfKey(before, key), 2)
        // the same cells, reordered, and one of them edited
        const after = [ { type: "button", id: "eq" }, { type: "thumb", w: 64 }, { type: "title" } ]
        compare(Keys.indexOfKey(after, key), 0)
        // and gone means gone, not "whatever took that slot"
        compare(Keys.indexOfKey([ { type: "thumb" }, { type: "title" } ], key), -1)
    }
}
