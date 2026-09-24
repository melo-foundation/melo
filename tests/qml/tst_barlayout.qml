import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// The bar renderer on a document of spacers, which need nothing from the
// app: flex cells share what is left, a centred cell's sides lay out from
// it, a cell under its minWidth steps aside, a variant's rows replace the
// document's under its width. The numbers are the rule in docs/bar-layout.md.
Item {
    width: 300; height: 100

    TestCase {
        name: "BarLayout"
        when: windowShown
        function cell(lay, r, i) { return lay.rowAt(r).cellAt(i) }
        function settle() { wait(60) }

        function test_flex_shares_the_leftover() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", flex: 1 }, { type: "spacer", w: 30 } ] } ] } })
            settle()
            compare(cell(lay, 0, 0).x, 0); compare(cell(lay, 0, 0).width, 50)
            compare(cell(lay, 0, 1).x, 60); compare(cell(lay, 0, 1).width, 200)
            compare(cell(lay, 0, 2).x, 270); compare(cell(lay, 0, 2).width, 30)
            lay.destroy()
        }
        // Either side on its own: a side that names its own padding wins; the
        // other still takes `pad`.
        function test_a_side_can_be_padded_on_its_own() {
            const flexed = (doc) => {
                const lay = flexC.createObject(null, { width: 300, doc: doc })
                settle(); return lay
            }
            // pad alone: both ends
            let lay = flexed({ height: 40, pad: 10, rows: [ { height: 20, cells: [
                { type: "spacer", flex: 1 } ] } ] })
            // the row is offset by the left pad, so a cell's x is its row's;
            // what the padding changes is the room the row has
            compare(cell(lay, 0, 0).width, 280, "pad takes off both ends")
            lay.destroy()
            // padRight alone on the document: the left keeps the theme's
            lay = flexed({ height: 40, pad: 10, padRight: 40, rows: [ { height: 20, cells: [
                { type: "spacer", flex: 1 } ] } ] })
            compare(cell(lay, 0, 0).width, 250, "only the right end pulls in")
            lay.destroy()
            // and a row may name one of its own, overriding the document's
            lay = flexed({ height: 40, pad: 10, rows: [ { height: 20, padRight: 60, cells: [
                { type: "spacer", flex: 1 } ] } ] })
            compare(cell(lay, 0, 0).width, 230, "the row's right padding wins")
            lay.destroy()
        }

        // Gap after. `gap` is the space before a cell; `gapAfter` holds the
        // last cell in a run off the end, and pushes the next cell away
        // without that cell naming a gap of its own.
        function test_a_cell_can_hold_the_space_after_it() {
            const flexed = (doc) => {
                const lay = flexC.createObject(null, { width: 300, doc: doc })
                settle(); return lay
            }
            // the flex cell is last: its gapAfter comes off its own width
            let lay = flexed({ height: 40, pad: 0, rows: [ { height: 20, gap: 0, cells: [
                { type: "spacer", w: 50 },
                { type: "spacer", flex: 1, gapAfter: 30 } ] } ] })
            compare(cell(lay, 0, 1).x, 50, "the run still starts where it did")
            compare(cell(lay, 0, 1).width, 220, "the trailing gap is held off the end")
            lay.destroy()
            // between two cells it ADDS to the next one's own gap
            lay = flexed({ height: 40, pad: 0, rows: [ { height: 20, gap: 0, cells: [
                { type: "spacer", w: 50, gapAfter: 12 },
                { type: "spacer", w: 40, gap: 8 },
                { type: "spacer", flex: 1 } ] } ] })
            compare(cell(lay, 0, 1).x, 70, "12 after the first plus 8 before the second")
            compare(cell(lay, 0, 2).x, 110, "and the run carries on from there")
            lay.destroy()
            // nothing set adds no space
            lay = flexed({ height: 40, pad: 0, rows: [ { height: 20, gap: 0, cells: [
                { type: "spacer", w: 50 },
                { type: "spacer", w: 40 } ] } ] })
            compare(cell(lay, 0, 1).x, 50, "no gapAfter, no space")
            lay.destroy()
        }

        // A maximum on a flex cell: it stops there, and the flex cell without
        // one takes what it left. Spacers across 300px, 10px gaps: 280 to share.
        function test_a_flex_cell_stops_at_its_maxW() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", flex: 1, maxW: 60 }, { type: "spacer", flex: 1 }, { type: "spacer", w: 10 } ] } ] } })
            settle()
            compare(cell(lay, 0, 0).width, 60)
            compare(cell(lay, 0, 1).x, 70); compare(cell(lay, 0, 1).width, 210)
            lay.destroy()
        }
        function test_a_centred_cell_and_its_sides() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 40 }, { type: "spacer", w: 100, centre: true }, { type: "spacer", w: 40 } ] } ] } })
            settle()
            compare(cell(lay, 0, 1).x, 100)           // centred
            compare(cell(lay, 0, 0).x, 50)            // hugs the centre, a gap before it
            compare(cell(lay, 0, 2).x, 210)           // hugs the centre, a gap after it
            lay.destroy()
        }
        function test_a_side_with_flex_fills_its_half() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 20 }, { type: "spacer", flex: 1 }, { type: "spacer", w: 100, centre: true },
                    { type: "spacer", flex: 1 }, { type: "spacer", w: 20 } ] } ] } })
            settle()
            compare(cell(lay, 0, 0).x, 0)             // from the edge
            compare(cell(lay, 0, 1).width, 60)        // 90 to the centre, less 20 and two gaps
            compare(cell(lay, 0, 4).x, 280)           // to the edge
            lay.destroy()
        }
        function test_a_cell_under_its_minWidth_steps_aside() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50, minWidth: 500 }, { type: "spacer", flex: 1 } ] } ] } })
            settle()
            verify(!cell(lay, 0, 0).visible)
            compare(cell(lay, 0, 1).x, 0); compare(cell(lay, 0, 1).width, 300)
            lay.width = 600; settle()
            verify(cell(lay, 0, 0).visible)
            compare(cell(lay, 0, 1).x, 60); compare(cell(lay, 0, 1).width, 540)
            lay.destroy()
        }
        function test_a_variant_replaces_the_rows_under_its_width() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 77, pad: 0,
                rows: [ { height: 20, cells: [ { type: "spacer", w: 10 } ] }, { height: 20, cells: [ { type: "spacer", w: 10 } ] } ],
                variants: [ { maxWidth: 400, height: 56, rows: [ { height: 20, cells: [ { type: "spacer", w: 10 } ] } ] } ] } })
            settle()
            compare(lay.rowDocs.length, 1); compare(lay.barHeight, Theme.bar(56))
            lay.width = 500; settle()
            compare(lay.rowDocs.length, 2); compare(lay.barHeight, Theme.bar(77))
            lay.destroy()
        }
        function test_a_gap_on_the_first_cell_insets_it_from_the_edge() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50, gap: 20 }, { type: "spacer", flex: 1 },
                    { type: "spacer", w: 60, centre: true }, { type: "spacer", flex: 1 }, { type: "spacer", w: 30, gap: 5 } ] } ] } })
            settle()
            compare(cell(lay, 0, 0).x, 20)            // the row's gap does not apply at the edge; the cell's own does
            compare(cell(lay, 0, 2).x, 120)           // centred
            compare(cell(lay, 0, 3).x, 190)           // the first after the centre: its gap is the gap from the centre, no inset
            compare(cell(lay, 0, 4).x, 270)           // to the edge, its gap before it
            lay.destroy()
        }
        function test_both_arrangements_stay_built_across_the_threshold() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 77, pad: 0,
                rows: [ { height: 20, cells: [ { type: "spacer", w: 10 }, { type: "spacer", w: 20 } ] } ],
                variants: [ { maxWidth: 400, height: 56, rows: [ { height: 20, cells: [ { type: "spacer", w: 10 } ] } ] } ] } })
            settle()
            const built = Theme.cellBuilds
            verify(lay.alt); compare(lay.rowAt(0).cellCount(), 1)
            lay.width = 500; settle()
            verify(!lay.alt); compare(lay.rowAt(0).cellCount(), 2)
            lay.width = 300; settle()
            verify(lay.alt); compare(lay.rowAt(0).cellCount(), 1)
            compare(Theme.cellBuilds, built)        // crossing twice built nothing: both sets were kept
            lay.destroy()
        }
        // A morph: the bar says it is morphing, a new document with other
        // cells arrives — the cell that goes squeezes to nothing where it
        // stood, the one that comes opens where it belongs, the others glide
        function test_a_morph_squeezes_cells_in_and_out() {
            const lay = flexC.createObject(null, { width: 300, bar: { morphing: false, docOverride: null, customising: false }, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", w: 30 }, { type: "spacer", w: 20 } ] } ] } })
            settle()
            compare(cell(lay, 0, 2).x, 100)
            lay.bar = { morphing: true, docOverride: null, customising: false }
            lay.doc = { height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", w: 20 }, { type: "spacer", w: 40 } ] } ] }
            wait(20)
            compare(lay.rowAt(0).cellCount(), 4)      // the one going is still there, on its way out
            verify(cell(lay, 0, 1).leaving)
            compare(cell(lay, 0, 3).x, 90)            // the one coming is where it belongs from its first frame
            wait(80)
            verify(cell(lay, 0, 1).width > 0 && cell(lay, 0, 1).width < 30)    // squeezing out
            verify(cell(lay, 0, 3).width > 0 && cell(lay, 0, 3).width < 40)    // squeezing in
            verify(cell(lay, 0, 2).x < 90 && cell(lay, 0, 2).x > 60)           // gliding
            wait(300)
            compare(lay.rowAt(0).cellCount(), 3)      // gone
            compare(cell(lay, 0, 1).x, 60); compare(cell(lay, 0, 2).x, 90); compare(cell(lay, 0, 2).width, 40)
            lay.destroy()
        }
        // An edit animates like a morph does. No morph is in flight here and
        // no drag: a row that has drawn once animates any later change to its
        // cells.
        function test_a_cell_added_by_an_edit_opens_where_it_belongs() {
            const lay = flexC.createObject(null, { width: 300, bar: { morphing: false, docOverride: null, customising: false }, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", w: 40 } ] } ] } })
            settle()
            compare(cell(lay, 0, 1).x, 60)
            verify(!cell(lay, 0, 0).gliding)          // nothing is moving yet
            lay.doc = { height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", w: 30 }, { type: "spacer", w: 40 } ] } ] }
            wait(20)
            compare(lay.rowAt(0).cellCount(), 3)
            verify(lay.rowAt(0).animating)            // the row is drawing the change
            verify(cell(lay, 0, 1).gliding)
            compare(cell(lay, 0, 1).x, 60)            // the new one opens where it belongs
            wait(80)
            verify(cell(lay, 0, 1).width > 0 && cell(lay, 0, 1).width < 30)   // still opening
            wait(400)
            compare(cell(lay, 0, 1).width, 30); compare(cell(lay, 0, 2).x, 100)
            verify(!lay.rowAt(0).animating)
            lay.destroy()
        }
        // A cell is keyed by its kind, so an edit reuses the item: the thumb
        // keeps its artwork and glides to its new size. Spacers are keyed by
        // their document (several per row, and a spacer is its width);
        // rebuilding one loses nothing.
        function test_an_edit_keeps_the_cell_and_glides() {
            const lay = flexC.createObject(null, { width: 400,
                bar: { morphing: false, docOverride: null, customising: false }, doc: {
                height: 40, pad: 0, rows: [ { height: 30, gap: 10, cells: [
                    { type: "thumb", w: 48, h: 28 }, { type: "spacer", w: 20 } ] } ] } })
            wait(150)
            const thumb = cell(lay, 0, 0)
            const builds = Theme.cellBuilds
            compare(thumb.width, Theme.art(48))
            lay.doc = { height: 40, pad: 0, rows: [ { height: 30, gap: 10, cells: [
                    { type: "thumb", w: 64, h: 37 }, { type: "spacer", w: 20 } ] } ] }
            wait(25)
            compare(Theme.cellBuilds, builds)         // nothing was rebuilt
            compare(cell(lay, 0, 0), thumb)           // the same item
            compare(lay.rowAt(0).cellCount(), 2)      // no insert, no remove
            const w = cell(lay, 0, 0).width
            verify(w > Theme.art(48) && w < Theme.art(64))   // gliding, not re-opening
            wait(400)
            compare(cell(lay, 0, 0).width, Theme.art(64))
            lay.destroy()
        }
        // A width change is laid out in the same frame. Deferred through
        // Qt.callLater, every frame of a resize would draw cells placed for the
        // previous width: jitter, worst in the centre layout, where every
        // cell's x comes off the width.
        function test_a_width_change_is_laid_out_before_the_frame() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 50 }, { type: "spacer", flex: 1 }, { type: "spacer", w: 30 } ] } ] } })
            settle()
            compare(cell(lay, 0, 2).x, 270)
            lay.width = 500
            compare(cell(lay, 0, 2).x, 470)      // no wait: before anything is drawn
            compare(cell(lay, 0, 1).width, 400)
            lay.width = 300
            compare(cell(lay, 0, 2).x, 270)
            lay.destroy()
        }
        function test_rows_stack_and_centre() {
            const lay = flexC.createObject(null, { width: 300, height: 77, doc: {
                height: 77, pad: 0, vcenter: true, vOffset: 2, rowGap: 4,
                rows: [ { height: 28, cells: [ { type: "spacer", w: 10 } ] }, { height: 24, cells: [ { type: "spacer", w: 10 } ] } ] } })
            settle()
            // 28 + 4 + 24 = 56 centred in 77, plus the offset
            compare(lay.rowAt(0).y, (77 - 56) / 2 + 2)
            compare(lay.rowAt(1).y, (77 - 56) / 2 + 2 + 28 + 4)
            lay.destroy()
        }
        // A document that names no pad takes the theme's player inset, each
        // side its own; one that names a pad keeps wearing it.
        function test_the_side_pad_falls_back_to_the_inset() {
            const row = [ { height: 20, cells: [ { type: "spacer", flex: 1 } ] } ]
            const lay = flexC.createObject(null, { width: 300, doc: { height: 40, rows: row } })
            settle()
            compare(lay.rowAt(0).x, 12); compare(lay.rowAt(0).width, 276)
            Theme.held = true
            Theme.ts.insets = { player: { left: 4, right: 18 } }; Theme.tsChanged(); settle()
            compare(lay.rowAt(0).x, 4); compare(lay.rowAt(0).width, 278)
            lay.doc = { height: 40, pad: 2, rows: row }; settle()
            compare(lay.rowAt(0).x, 2); compare(lay.rowAt(0).width, 296)
            delete Theme.ts.insets; Theme.tsChanged(); Theme.held = false
            lay.destroy()
        }
        // A plate's tail runs level at 0.7 r above centre to a corner
        // `backingTail` px right of the last cell's circle, then sweeps to the
        // bottom line on a quarter-ellipse twice as wide as the plate is deep.
        // A 20px spacer at x=0, pad 10, is a circle at (10, y) radius 10; tail
        // 40 puts the corner at x = 60, y = centre - 7; the bottom is centre +
        // 10 + drop 5, 22 px down, so the sweep lands 44 px back.
        function test_a_plate_tail_reaches_its_point() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 20, backing: "accent", backingPad: 10, backingTail: 40, backingDrop: 5 },
                    { type: "spacer", w: 20 } ] } ] } })
            settle()
            const row = lay.rowAt(0)
            compare(row.backings.length, 1)
            compare(row.backings[0].tail, 40)
            const d = row.platePath(row.backings[0])
            const cy = row.cellAt(0).y
            verify(d.indexOf(" L 60.00 " + (cy - 7).toFixed(2)) >= 0, d)     // the level top runs to the corner
            verify(d.indexOf(" A44.00 22.00 0 0 1 16.00 " + (cy + 15).toFixed(2)) >= 0, d)   // the sweep to the bottom line
            lay.destroy()
        }
        function test_a_plate_without_a_tail_ends_at_its_circle() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 20, backing: "accent", backingPad: 10 } ] } ] } })
            settle()
            const row = lay.rowAt(0)
            compare(row.backings[0].tail, 0)
            const d = row.platePath(row.backings[0])
            verify(d.indexOf("60.00") < 0, d)
            lay.destroy()
        }
        // Room in a panel row: `padTop` and `padBottom` deepen the row past
        // its tallest cell, up to its height, and the cell sits between them.
        // A thumb is the one cell that is a stated height without the app.
        function test_a_row_pads_above_and_below_its_cells() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 80, pad: 0, rows: [ { height: 60, padTop: 4, padBottom: 9, cells: [
                    { type: "thumb", w: 10, h: 20 } ] } ] } })
            settle()
            const row = lay.rowAt(0), c = cell(lay, 0, 0)
            compare(row.usedH, c.implicitHeight + 13)
            compare(c.y, 4)
            // the height is still the ceiling
            lay.doc = { height: 80, pad: 0, rows: [ { height: 30, padTop: 4, padBottom: 9, cells: [
                { type: "thumb", w: 10, h: 20 } ] } ] }
            settle()
            compare(lay.rowAt(0).usedH, 30)
            lay.destroy()
        }
        // A drop below nought raises the bottom line into the cells: the
        // circle's bottom is at centre + r + drop, so r 10 and drop -6 put
        // it 4 px under the centre, and the side steps up to meet it.
        function test_a_negative_drop_raises_the_plates_bottom() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 20, backing: "accent", backingPad: 10, backingDrop: -6 } ] } ] } })
            settle()
            const row = lay.rowAt(0), cy = row.cellAt(0).y
            const d = row.platePath(row.backings[0])
            verify(d.indexOf(" L20.00 " + (cy - 6).toFixed(2)) >= 0, d)            // the side, up to the raised line
            verify(d.indexOf(" A10.00 10.00 0 0 1 0.00 " + (cy - 6).toFixed(2)) >= 0, d)   // the bottom arc round it
            lay.destroy()
        }
        // The tail is the run's: named on any cell of it, the last word wins
        function test_a_tail_named_on_a_later_cell_is_the_runs() {
            const lay = flexC.createObject(null, { width: 300, doc: {
                height: 40, pad: 0, rows: [ { height: 20, gap: 10, cells: [
                    { type: "spacer", w: 20, backing: "accent", backingPad: 10 },
                    { type: "spacer", w: 20, backing: "accent", backingPad: 10, backingTail: 30 } ] } ] } })
            settle()
            compare(lay.rowAt(0).backings.length, 1)
            compare(lay.rowAt(0).backings[0].tail, 30)
            lay.destroy()
        }
    }
    Component { id: flexC; BarLayout { height: 40 } }
}
