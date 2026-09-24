# Bar layout

A bar layout is a JSON document of rows of cells. The theme settings `barMain`, `barNp` and `barMini` each name one by id; defaults `rows`, `centre`, `rows`. An unknown id draws `rows`. Built in: `rows` `centre` `strip` `ministrip`.

`centre`'s narrow variant follows **Centre scrub bar**: **Window edge** always uses it, **Under the controls** never does, **Auto** uses it by width in the main window and never in the mini player.

To edit a slot's layout, use one of:

- **Settings › Appearance** (Mode: **Full**) **› Player › Arrange**, then **Main**, **Now playing** or **Mini player**.
- Right-click the player bar › **Edit layout**. This edits the slot the bar is showing.

Edits stay unsaved (Custom) until **Save** or **Save as**. Keep an edited built-in with **Save as**.

```json
{
  "id": "my-strip", "name": "My strip", "height": 56, "pad": 12, "vcenter": true,
  "rows": [
    { "height": 24, "gap": 6, "cells": [
      { "type": "thumb", "w": 40, "h": 24, "gap": 8 },
      { "type": "title", "flex": 1, "lines": 1, "gap": 8 },
      { "type": "prev", "size": 24, "glyph": 15, "gap": 16 },
      { "type": "play", "size": 24, "glyph": 15, "centre": true, "gap": 8 },
      { "type": "next", "size": 24, "glyph": 15, "gap": 8 },
      { "type": "scrub", "flex": 1, "h": 20, "track": 3, "hover": 6, "gap": 14 },
      { "type": "time", "minWidth": 500, "gap": 8 },
      { "type": "button", "id": "eq", "gap": 14 },
      { "type": "button", "id": "queue" },
      { "type": "button", "id": "vis", "mini": true } ] } ]
}
```

## Document

| key | value | default |
|---|---|---|
| `height` | px, min 24 | 77 |
| `pad` | px, left and right | theme's player inset |
| `padLeft` `padRight` | px, one side; overrides `pad` | `pad` |
| `top` | px above the first row | theme's player top inset |
| `vcenter` | bool, centre the rows vertically | false |
| `vOffset` | px, with `vcenter` | 0 |
| `rowGap` | px between rows | 4 |
| `rows` | list of rows | — |
| `variants` | list of `{ "maxWidth", "height", "top", "rows" }`; the first whose `maxWidth` is wider than the bar replaces `rows`, `height` and `top` | — |

`maxWidth`: px, or `"narrow"` (820).

## Row

| key | value | default |
|---|---|---|
| `height` | px, the most the row grows to; a row whose cells have no height (only spacers) is this tall | 24 |
| `gap` | px between cells | 8 |
| `pad` | px, left and right, this row | the document's |
| `padLeft` `padRight` | px, one side; overrides `pad` | `pad` |
| `padTop` `padBottom` | px above / below the cells, counted inside `height` | 0 |
| `at` | `bottom`: row sits on the bar's bottom edge, full bar height | — |
| `role` | palette role filled behind the row | — |
| `radius` | px, with `role` | 0 |
| `ink` | palette role for the row's text | — |
| `cells` | list of cells, left to right | — |

`role` and `ink` accept any palette key, including ones the theme adds.

## Cell: any type

| key | value | default |
|---|---|---|
| `type` | see below | `spacer` |
| `flex` | share of the row's leftover width | 0 |
| `maxW` | px, widest the cell is drawn | none |
| `centre` | bool, one per row; the cell sits at the row's middle and the cells on each side pack against it; a side with a `flex` cell fills its half | false |
| `gap` | px before the cell | the row's `gap` (0 at a row edge) |
| `gapAfter` | px after the cell | 0 |
| `minWidth` | px; a bar narrower than this hides the cell | — |
| `dy` | px, vertical nudge | 0 |
| `mini` | bool, shown in `barMini` only | false |
| `backing` | palette role; adjacent cells with the same role share one plate | — |
| `backingPad` | px added to the radius of each circle of the plate | 0 |
| `backingNeck` | px, radius of the join between two circles | 1.5 × the larger circle's radius |
| `backingDrop` | px the plate extends below the cells; negative raises it | 0 |
| `backingTail` | px the plate extends right of the run's last cell | 0 |

## Cell types

| type | keys | defaults |
|---|---|---|
| `thumb` | `w` `h` `r` | 48 · 28 · 2 |
| `title` | `lines` 1 or 2 · `artist` `none` to hide · `size` · `skeleton` bool, placeholder bars with no track | 2 · shown · 13 (2 lines), 12 (1 line) · true |
| `artist` | `size` | 11 |
| `prev` `play` `next` | `size` · `glyph` · `disc` bool · `face` palette role of the disc, `<face>Hover` on hover · `w` `h` pill size | 28 · round(0.62 × size) · false · `accent` · square |
| `playdisc` | as `play`, with `disc: true` | |
| `scrub` | `w` · `fitMax` `fitMargin` (width = min(bar − 2 × fitMargin, fitMax)) · `h` · `track` · `hover` · `radius` (ignored under a square-scrubber theme) · `bubble` · `edge` bool, track on the cell's bottom edge · `glide` · `trackRole` | 200 · — / 0 · 24 · 6 · track + 2 · round, 0 with `edge` · true · false · false · `scrubberTrack` |
| `elapsed` `total` `countdown` | `size` | 11 |
| `time` | `sep` · `second` `total` or `countdown` · `size` | `" / "` · `total` · 11 |
| `button` | `id` (required): `library` `radio` `eq` `queue` `vis` `plugin:<pluginId>.<id>` · `size` | — · 22 |
| `spacer` | `w` | 0 |
| `volume` | `w` | 90 |

## Files

`~/.config/melo/presets/layout/<id>.json` (`$MELO_CONFIG_DIR/presets/layout/` when set): `{ "id", "name", "kind": "layout", "body": <document> }`. A file with an empty `id` is skipped. An `id` equal to a built-in's draws the built-in. Restart melo to load a file copied in by hand.

**Import** takes a file with `"kind": "layout"` and a non-empty `body`, and gives it a new id. **Export** writes the same format.

| arranger button | shown |
|---|---|
| Save | edited custom layout |
| Save as | edited layout |
| Discard | edited layout |
| Rename, Delete | unedited custom layout |
| Export, Import | always |

## Adding a cell type

1. Add `src/qml/components/barcells/<Name>Cell.qml` with `required property var host` (the `BarCell`; read keys from `host.doc`), setting `implicitWidth` and `implicitHeight`.
2. In `src/qml/components/BarCell.qml`, add a `Component` for it and a case in the `sourceComponent` ternary.
3. Add it to `elements` in `src/qml/components/BarArrange.qml`, and a case in `defaultCell` if a new cell needs keys set.
4. Add a row to the cell-type table above.
5. Add a test in `tests/qml/tst_barlayout.qml` if it lays out differently from a spacer.
