import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

Item {
    width: 900; height: 800
    // The picker is a window of its own: what things have to fit inside is
    // its content area.
    ColorPicker { id: picker }
    TestCase {
        name: "ColorPicker"
        when: windowShown
        property var committed: null
        readonly property var stops: ["#14345a", "#277b8a", "#7dc4af", "#cbbc85", "#de799e", "#a3abff"]

        function initTestCase() { Theme.held = true }
        // Per test function: failOnWarning is scoped to its caller. Advanced by
        // default; the simple surface has its own cases. Allowed warnings: the
        // offscreen platform refusing size hints, and the Melo module, which
        // lives in melo's binary (blended layers do not draw here, as Surface
        // degrades too).
        function init() {
            failOnWarning(/^(?!This plugin does not support propagateSizeHints)(?!.*module "Melo" is not installed)/)
            picker.setAdvanced(true)
        }
        function cleanup() {
            picker.reject()
            delete Theme.ts.uiScale
            delete Theme.ts.fontScale
            delete Theme.ts.controlScale
            Theme.tsChanged()
            committed = null
        }
        function cleanupTestCase() { Theme.held = false }
        // resolved on first use: the window's contents exist by then
        property Item hostItem: null
        function host() { if (!hostItem) hostItem = findChild(picker, "pickerBody"); return hostItem }
        function part(name) { return findChild(host(), name) }
        // the gallery of fills is a window of its own
        function sel() { return findChild(picker, "fillSelect") }
        function selPart(name) { return findChild(findChild(sel(), "fillSelectBody"), name) }
        function openSel() { sel().openBeside(); wait(40); return sel() }
        function open(w, h, scale, kind, colours, fontScale, controlScale) {
            // The standalone singleton has a plain settings object, not a
            // backend. Emit its change signal just as a backend update would.
            Theme.ts.uiScale = scale
            Theme.ts.fontScale = fontScale || 1
            Theme.ts.controlScale = controlScale || 1
            Theme.tsChanged()
            picker.open({ colour: "#315080", source: kind, params: { speed: 0, colours: colours || [] } },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            // At or above the window's own minimum. The offscreen platform
            // does not enforce a minimum size, so a test can put the window
            // somewhere no window manager would let a person drag it.
            picker.width = Math.max(picker.minimumWidth, w)
            picker.height = Math.max(picker.minimumHeight, h)
            wait(40)
            return part("colourPickerDialog")
        }
        function insideOf(area, item) {
            verify(item && item.visible, "control is visible")
            const tl = item.mapToItem(area, 0, 0)
            const br = item.mapToItem(area, item.width, item.height)
            verify(tl.x >= -0.5 && tl.y >= -0.5 && br.x <= area.width + 0.5 && br.y <= area.height + 0.5,
                   item.objectName + " outside " + area.width + "x" + area.height + ": " + tl + " .. " + br)
        }
        function inside(item) {
            verify(item && item.visible, "control is visible")
            const h = host()
            const tl = item.mapToItem(h, 0, 0)
            const br = item.mapToItem(h, item.width, item.height)
            verify(tl.x >= -0.5 && tl.y >= -0.5 && br.x <= h.width + 0.5 && br.y <= h.height + 0.5,
                   item.objectName + " outside " + h.width + "x" + h.height + ": " + tl + " .. " + br)
        }
        function noScroll(item) {
            verify(item.contentY === undefined, "no scrolling container in the picker")
            for (const child of item.children) noScroll(child)
        }
        function test_fit_data() {
            return [
                { tag: "settings", w: 480, h: 520, scale: 1 },
                { tag: "minimum-settings", w: 400, h: 380, scale: 1 },
                { tag: "short-host", w: 400, h: 320, scale: 1 },
                { tag: "scaled-settings", w: 480, h: 520, scale: 1.25 },
                { tag: "scaled-short", w: 400, h: 380, scale: 1.25 },
                { tag: "large-controls", w: 600, h: 650, scale: 1.5 },
                { tag: "large-font", w: 400, h: 380, scale: 1, fontScale: 1.3 },
                { tag: "control-scale", w: 400, h: 380, scale: 1, controlScale: 1.4 }
            ]
        }
        function test_fit(data) {
            for (const kind of ["colour", "adaptive", "image", "rainbow", "agate", "opal", "nebula", "mercury", "lucent", "gyroid", "kaleido", "raster", "bevel", "contour", "rim", "trace", "tidal", "cloud", "toon", "comic", "doodle"]) {
                const dialog = open(data.w, data.h, data.scale, kind, Theme.fillPalette(kind) ? stops : [], data.fontScale, data.controlScale)
                fuzzyCompare(Theme.uiScale, data.scale, 0.001)
                inside(dialog)
                inside(part("pickerAccept"))
                // the hex belongs to the colour: a fill with none hides it
                if (picker.needsColour) inside(part("pickerCode"))
                inside(part("pickerEditor"))
                inside(part("pickerFill"))
                inside(part("pickerLayers"))
                if (picker.needsColour) {
                    inside(part("saturationValue"))
                    inside(part("hueStrip"))
                    inside(part("alphaStrip"))
                }
                for (const lever of picker.levers) inside(part("pickerLever_" + lever.key))
                if (picker.twoColours) {
                    const palette = part("paletteStops")
                    for (const swatch of palette.children) if (swatch.visible && swatch.width > 0) inside(swatch)
                }
                noScroll(host())
                openSel()
                const area = findChild(sel(), "fillSelectBody")
                for (const source of sel().kinds) {
                    const tile = selPart("fillTile_" + source)
                    insideOf(area, tile)
                    verify(!findChild(tile, "fillLabel_" + source).truncated,
                           "the gallery still shows the full name: " + source)
                }
                verify(selPart("fillTile_" + kind) !== null, "tile for " + kind + " kinds=" + JSON.stringify(sel().kinds))
                mouseClick(selPart("fillTile_" + kind))
                wait(30)
                sel().visible = false
                compare(picker.sourceMode, kind)
                inside(part("pickerAccept"))
                mouseClick(part("pickerAccept"))
                verify(!picker.visible)
                verify(committed !== null)
                compare(Theme.sourceOf(committed), kind)
                committed = null
            }
        }
        function test_palette_and_controls_still_edit() {
            open(400, 380, 1, "lucent", stops)
            picker.editColour(5)
            picker.loadOnWheel(Qt.color("#804080ff"))
            picker.livePreview()
            part("pickerLever_stSpeed").apply(-0.5)
            part("pickerLever_stScale").apply(2)
            part("pickerLever_stAngle").apply(90)
            picker.blendMode = "screen"
            mouseClick(part("pickerAccept"))
            compare(committed.source, "lucent")
            compare(committed.params.colours[5], "#804080ff")
            compare(committed.params.speed, -0.5)
            compare(committed.params.scale, 2)
            compare(committed.params.angle, 90)
            compare(committed.blend, "screen")
        }
        // One instance serves every call site, so an open carries nothing
        // from the last one: a code field that kept the previous entry's code
        // while focused would show the next role a colour it does not have,
        // and committing would write that colour over it.
        function test_a_second_open_carries_nothing_from_the_first() {
            picker.open({ colour: "#112233", source: "opal", params: { speed: 0, colours: [] } },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            const code = part("pickerCode")
            code.forceActiveFocus()
            code.text = "#ff0000"
            wait(10)
            verify(code.activeFocus, "the field is being typed in, as it is when a code is pasted")
            picker.open("#00ff00", ({ commit: v => committed = v }))
            wait(30)
            compare(code.text, "#00ff00")
            compare(picker.sourceMode, "colour")
            compare(picker.baseKept, "#00ff00")
            compare(picker.original.toString(), "#00ff00")
            verify(!part("pickerFill").visible, "and nothing the previous call site allowed")
        }

        // ---- the layer stack ----
        function test_a_stack_is_built_and_committed() {
            open(520, 620, 1, "opal", [])
            compare(picker.layerCount, 1)
            picker.addLayer()
            compare(picker.layerCount, 2)
            compare(picker.layerAt, 1, "the new layer is the one being edited")
            // a layer arrives still, which is the whole mitigation for no cap
            compare(picker.stSpeed, 0)
            picker.sourceMode = "rainbow"
            picker.loadOnWheel(Qt.color("#8040c0"))
            findChild(part("pickerEditor"), "pickerLever_layerOpacity").apply(0.5)
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2)
            compare(Theme.sourceOf(committed.layers[0]), "opal")
            compare(Theme.sourceOf(committed.layers[1]), "rainbow")
            compare(Theme.colorOf(committed.layers[1], "#000000").toString(), "#8040c0")
            fuzzyCompare(committed.layers[1].opacity, 0.5, 0.01)
            verify(committed.layers[0].opacity === undefined, "a full layer is not written")
        }

        function test_a_layer_keeps_what_the_controls_never_touched() {
            // a stack whose second layer carries an option this build has no
            // control for: selecting away from it and back must not drop it
            picker.open({ layers: [ { colour: "#112233", source: "opal", params: { speed: 0 } },
                                    { colour: "#445566", source: "doodle",
                                      params: { speed: 0, grain: 0.7 } } ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            compare(picker.layerCount, 2)
            picker.selectLayer(1)
            compare(picker.sourceMode, "doodle")
            picker.selectLayer(0)
            picker.selectLayer(1)
            mouseClick(part("pickerAccept"))
            compare(committed.layers[1].params.grain, 0.7)
        }

        function test_reorder_remove_and_mute() {
            picker.open({ layers: [ { colour: "#112233", source: "opal", params: { speed: 0 } },
                                    { colour: "#445566", source: "gloss", params: { speed: 0 } } ] },
                        ({ commit: v => committed = v, preview: v => preview = v, blend: true, adaptive: true }))
            wait(30)
            picker.selectLayer(1)
            picker.moveLayer(-1)
            compare(picker.layerAt, 0)
            compare(Theme.sourceOf(picker.layerEntries()[0]), "gloss")
            compare(Theme.sourceOf(picker.layerEntries()[1]), "opal")
            // muting is a way of seeing what a layer does, not an edit
            picker.toggleMute(0)
            verify(!picker.layerShown(0))
            compare(picker.previewValue().layers, undefined, "one layer left is written flat")
            compare(Theme.sourceOf(picker.previewValue()), "opal")
            compare(picker.currentValue().layers.length, 2, "and the muted layer is still committed")
            picker.toggleMute(0)
            picker.removeLayer()
            compare(picker.layerCount, 1)
            mouseClick(part("pickerAccept"))
            compare(Theme.sourceOf(committed), "opal", "a stack of one goes back out flat")
            verify(committed.layers === undefined)
        }
        property var preview: null

        // The box holds a colour. The whole entry is what Copy moves (a stack
        // of fills with their own options is not something to read in a text
        // box), and typing a colour dyes rather than stripping the fill off.
        function test_the_box_is_a_hex_field() {
            open(520, 620, 1, "opal", [])
            const code = part("pickerCode")
            compare(code.text, "#315080")
            picker.addLayer()
            compare(code.text, picker.hexOf(picker.current))
            verify(picker.copyEntry !== undefined)
            verify(Theme.entryToCode(picker.currentValue()).indexOf("+") > 0,
                   "and Copy moves the stack, separator and all")
            // the alpha first, as the code writes it, and only when there is one
            picker.alpha = 0.5; picker.syncHex(true)
            compare(code.text.length, 9)
            compare(code.text.substr(1, 2), "80")
            picker.alpha = 1; picker.syncHex(true)
            compare(code.text.length, 7)
            // a bare hex dyes the layer being edited
            picker.sourceMode = "rainbow"
            verify(picker.applyText("#204080"))
            compare(picker.sourceMode, "rainbow", "the fill survives a colour typed over it")
            compare(picker.current.toString(), "#204080")
            verify(picker.applyText("#80204080"), "and takes an alpha as the code writes one")
            compare(picker.current.toString(), "#80204080")
            verify(!picker.applyText("#nope"), "what cannot be a colour is refused")
            compare(picker.current.toString(), "#80204080", "and changes nothing")
            // a whole code replaces
            verify(picker.applyText("#112233s0f8080400+#445566"))
            compare(picker.layerCount, 2)
            compare(Theme.sourceOf(picker.layers[0]), "opal")
        }

        // The box is the selected layer's colour, never the entry's code, so
        // typing over it changes that colour and nothing else.
        function test_the_box_reads_the_selected_layers_colour() {
            picker.open({ layers: [ ({ colour: "#112233", source: "opal", params: { speed: 0.4 } }),
                                    ({ colour: "#445566", source: "gloss", params: { speed: 0 } }) ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            const code = part("pickerCode")
            compare(code.text, "#112233")
            picker.selectLayer(1)
            compare(code.text, "#445566")
            picker.selectLayer(0)
            compare(code.text, "#112233")
            // typing sets that colour and nothing else
            verify(picker.applyText("#ff0000"))
            picker.livePreview()
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2)
            compare(committed.layers[0].colour, "#ff0000")
            compare(Theme.sourceOf(committed.layers[0]), "opal")
            fuzzyCompare(committed.layers[0].params.speed, 0.4, 0.001)
            compare(committed.layers[1].colour, "#445566")
            compare(Theme.sourceOf(committed.layers[1]), "gloss")
        }

        function test_typing_a_hex_edits_the_selected_stop() {
            open(520, 620, 1, "lucent", stops)
            picker.editColour(2)
            compare(part("pickerCode").text, stops[2])
            verify(picker.applyText("#00ff00"))
            picker.livePreview()
            mouseClick(part("pickerAccept"))
            compare(committed.params.colours[2], "#00ff00")
            compare(committed.params.colours[1], stops[1])
            compare(committed.params.colours[3], stops[3])
        }

        // A gradient is its order: the stops move, the colours do not.
        function test_the_stops_reorder() {
            open(520, 620, 1, "lucent", stops)
            verify(!part("stopLeft").visible, "nothing selected, nothing to move")
            picker.editColour(0)
            wait(30)   // the arrows appear: the row is not laid out until then
            verify(!part("stopLeft").enabled, "the first stop has no left")
            verify(part("stopRight").enabled)
            mouseClick(part("stopRight"))
            compare(picker.editing, 1, "the stop stays selected where it landed")
            compare(picker.liveStops[0], stops[1])
            compare(picker.liveStops[1], stops[0])
            picker.editColour(5)
            wait(30)
            verify(!part("stopRight").enabled, "the last stop has no right")
            mouseClick(part("stopLeft"))
            compare(picker.editing, 4)
            mouseClick(part("pickerAccept"))
            compare(committed.params.colours[0], stops[1])
            compare(committed.params.colours[1], stops[0])
            compare(committed.params.colours[4], stops[5])
            compare(committed.params.colours[5], stops[4])
        }

        // Simple is a dye: no fill selection at all, and it never changes what
        // an entry is. A stack visited in Simple comes back a stack.
        function test_simple_dyes_and_changes_nothing_else() {
            picker.setAdvanced(false)
            picker.open({ layers: [ { colour: "#112233", source: "opal", params: { speed: 0 } },
                                    { colour: "#445566", source: "gloss", params: { speed: 0 } } ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            verify(!part("pickerFill").visible, "no fill selection")
            verify(!part("pickerLayers").visible, "and no stack to take apart")
            verify(!part("paletteStops").visible)
            compare(picker.levers.length, 0)
            inside(part("saturationValue")); inside(part("hueStrip")); inside(part("alphaStrip"))
            inside(part("pickerAccept"))
            picker.loadOnWheel(Qt.color("#c04080"))
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2, "still a stack of two")
            compare(Theme.sourceOf(committed.layers[0]), "opal", "still an opal")
            compare(Theme.sourceOf(committed.layers[1]), "gloss")
            // every layer with a base colour takes the dye, not just the one
            // the wheel was holding
            compare(Theme.colorOf(committed.layers[0], "#000000").toString(), "#c04080")
            compare(Theme.colorOf(committed.layers[1], "#000000").toString(), "#c04080")
        }

        function test_simple_and_advanced_lose_nothing_either_way() {
            picker.setAdvanced(true)
            picker.open({ layers: [ { colour: "#112233", source: "opal",
                                      params: { speed: 0.4, scale: 3, angle: 90 } },
                                    { colour: "#445566", source: "gloss", params: { speed: 0 },
                                      opacity: 0.5 } ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            picker.setAdvanced(false)
            wait(20)
            picker.setAdvanced(true)
            wait(20)
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2)
            compare(committed.layers[0].params.speed, 0.4)
            compare(committed.layers[0].params.scale, 3)
            compare(committed.layers[0].params.angle, 90)
            fuzzyCompare(committed.layers[1].opacity, 0.5, 0.01)
        }

        // An entry Simple could not edit does not get the Simple view, and
        // does not get a toggle offering one either.
        function test_an_entry_with_no_base_colour_is_advanced() {
            picker.setAdvanced(false)
            picker.open({ source: "adaptive", amounts: { hue: 0, lum: -1, sat: 0, opacity: 1 } },
                        ({ commit: v => committed = v, adaptive: true }))
            wait(30)
            verify(!picker.canDye)
            verify(picker.advanced, "an entry with nothing to dye opens advanced")
            verify(!findChild(picker, "pickerMode").visible)
        }

        // ---- the fill selector, in its own window ----
        function test_the_fill_selector_picks_for_the_selected_layer() {
            open(460, 460, 1, "opal", [])
            picker.addLayer()
            compare(picker.layerAt, 1)
            openSel()
            verify(sel().visible)
            mouseClick(selPart("fillTile_lava"))
            wait(30)
            compare(picker.sourceMode, "lava", "applied at once, without dismissing")
            verify(sel().visible, "and the gallery stays open to compare against")
            mouseClick(selPart("fillTile_rim"))
            wait(30)
            compare(picker.sourceMode, "rim")
            // the layer below is untouched
            compare(Theme.sourceOf(picker.layerEntries()[0]), "opal")
            sel().visible = false
        }

        function test_the_filters_narrow_the_gallery() {
            open(460, 460, 1, "opal", [])
            openSel()
            const all = sel().kinds.length
            verify(all > 20, "every kind and every plugin's")
            mouseClick(selPart("fillFilter_shape"))
            wait(20)
            verify(sel().kinds.length < all)
            for (const k of sel().kinds) verify(Theme.fillShape(k), k + " is shape-aware")
            mouseClick(selPart("fillFilter_palette"))
            wait(20)
            for (const k of sel().kinds) verify(Theme.fillShape(k) && Theme.fillPalette(k), k)
            mouseClick(selPart("fillFilter_shape"))
            mouseClick(selPart("fillFilter_palette"))
            wait(20)
            compare(sel().kinds.length, all)
            sel().visible = false
        }

        function test_the_gallery_goes_when_the_picker_does() {
            open(460, 460, 1, "opal", [])
            openSel()
            verify(sel().visible)
            picker.reject()
            wait(20)
            verify(!sel().visible, "an orphan gallery has nothing to select for")
        }

        // ---- a kind's own options ----
        function settings() { return findChild(picker, "fillSettings") }
        function optRow(name) { return findChild(findChild(settings(), "fillSettingsBody"), "fillOption_" + name) }

        function test_a_kinds_own_options_are_set_and_committed() {
            open(460, 460, 1, "raster", [])
            verify(part("pickerFillSettings").visible, "raster names options of its own")
            settings().openBeside(); wait(40)
            compare(settings().options.length, 2)
            // the table's default is what an entry that names no value has
            compare(optRow("pixels").amount, 48)
            compare(optRow("trail").amount, 18)
            optRow("pixels").apply(96)
            optRow("trail").apply(30)
            wait(30)
            mouseClick(part("pickerAccept"))
            compare(committed.params.pixels, 96)
            compare(committed.params.trail, 30)
            compare(committed.source, "raster")
            settings().visible = false
        }

        function test_expanded_material_settings_fit_and_commit_data() {
            const rows = []
            for (const kind of ["toon", "bevel", "cloud"])
                for (const scale of [1, 1.5]) rows.push({ tag: kind + "-" + scale, kind: kind, scale: scale })
            return rows
        }
        function test_expanded_material_settings_fit_and_commit(data) {
            open(400, 380, data.scale, data.kind, [], 1.3)
            settings().openBeside()
            wait(60)
            const area = settings().contentItem
            const body = findChild(settings(), "fillSettingsBody")
            noScroll(body)
            compare(settings().options.length, 8)
            for (const option of settings().options) {
                const row = findChild(body, "fillOption_" + option.name)
                if (row.shown) insideOf(area, row)
                if (!option.toggle) {
                    const value = option.to === option.value ? option.from : option.to
                    row.apply(value)
                    fuzzyCompare(picker.optionOf(option.name), value, 0.001)
                }
            }
            if (data.kind === "bevel") {
                const raised = findChild(body, "fillToggle_inset_0")
                compare(findChild(raised, "fillToggleInk").ink, "textOnAccent")
                mouseClick(findChild(body, "fillToggle_inset_1"))
                compare(picker.optionOf("inset"), 1)
            }
            picker.accept()
            verify(committed !== null)
            const saved = Theme.styledOf(committed).own
            for (const option of settings().options)
                if (!option.toggle) fuzzyCompare(saved[option.name], option.to === option.value ? option.from : option.to, 0.001, option.name)
        }

        // A kind with only the three levers every kind understands has no
        // button: one that opens an empty window is worse than none.
        function test_a_kind_with_no_options_has_no_button() {
            open(460, 460, 1, "rainbow", [])
            compare(Theme.fillOptions("rainbow").length, 0)
            verify(!part("pickerFillSettings").visible)
        }

        // An option a theme names but this build has never heard of rides
        // back out untouched, so opening a role here does not flatten what a
        // later melo wrote.
        function test_an_unknown_option_survives_a_visit() {
            picker.open({ colour: "#ff0000", source: "raster",
                          params: { speed: 0, scale: 1, angle: 0, pixels: 64, wormhole: 3 } },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            compare(picker.optionOf("pixels"), 64, "a value the table knows")
            mouseClick(part("pickerAccept"))
            compare(committed.params.pixels, 64)
            compare(committed.params.wormhole, 3, "and one it does not")
        }

        function test_the_settings_go_when_the_kind_stops_having_any() {
            open(460, 460, 1, "raster", [])
            settings().openBeside(); wait(40)
            verify(settings().visible)
            openSel()
            mouseClick(selPart("fillTile_rainbow"))
            wait(40)
            verify(!settings().visible, "rainbow has none, so there is nothing to show")
            sel().visible = false
        }

        // ---- phase, and A/B ----
        function test_a_phase_offset_is_per_layer() {
            open(460, 460, 1, "opal", [])
            picker.addLayer()
            compare(picker.layerCount, 2)
            const lever = findChild(part("pickerEditor"), "pickerLever_layerPhase")
            verify(lever, "a second layer is where a phase offset means anything")
            lever.apply(0.4)
            mouseClick(part("pickerAccept"))
            fuzzyCompare(committed.layers[1].phase, 0.4, 0.01)
            verify(committed.layers[0].phase === undefined, "0 is not written")
            // and it survives a code
            const back = Theme.codeToEntry(Theme.entryToCode(committed))
            fuzzyCompare(Theme.layersOf(back)[1].phase, 0.4, 0.01)
        }

        function test_comparing_shows_the_entry_as_it_was_opened() {
            let preview = null
            picker.open({ colour: "#112233", source: "opal", params: { speed: 0 } },
                        ({ commit: v => committed = v, preview: v => preview = v,
                           blend: true, adaptive: true }))
            wait(30)
            picker.loadOnWheel(Qt.color("#ff0000"))
            picker.livePreview()
            wait(60)
            compare(Theme.colorOf(preview, "#000000").toString(), "#ff0000")
            picker.comparing = true
            compare(Theme.colorOf(preview, "#000000").toString(), "#112233", "what was there")
            compare(Theme.sourceOf(preview), "opal")
            picker.comparing = false
            compare(Theme.colorOf(preview, "#000000").toString(), "#ff0000", "and back")
            // comparing is a glance, not an edit
            mouseClick(part("pickerAccept"))
            compare(Theme.colorOf(committed, "#000000").toString(), "#ff0000")
        }

        // ---- swatches ----
        function shelf() { return findChild(picker, "swatchShelf") }
        function openShelf() { shelf().openBeside(); wait(40); return shelf() }

        // A personal swatch is quick access: applied by value, never stamped,
        // so changing it later changes nothing already placed.
        function test_a_personal_swatch_is_applied_by_value() {
            open(460, 460, 1, "opal", [])
            picker.addLayer()
            picker.sourceMode = "gloss"
            picker.loadOnWheel(Qt.color("#8040c0"))
            openShelf()
            shelf().swatches = []
            shelf().add("glass rim")
            compare(shelf().swatches.length, 1)
            const id = shelf().swatches[0].id
            compare(shelf().swatches[0].entry.layers.length, 2, "the whole stack, not the top of it")

            picker.open("#112233", ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            compare(picker.layerCount, 1)
            picker.applySwatch(id, shelf().swatches[0].entry, false)
            wait(30)
            compare(picker.layerCount, 2, "a copy of the stack, written in")
            compare(picker.entryFrom, "", "and no stamp: it is this role's own now")
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2)
            verify(committed.from === undefined)
            compare(Theme.sourceOf(committed), "opal")
            shelf().visible = false
        }

        // A theme swatch is used: a role that takes one is stamped with it,
        // an edit by hand lets go of the stamp, and changing the swatch
        // reaches every role still using it (which needs the backend; what
        // is asserted here is the stamp and the entry it writes).
        function test_a_theme_swatch_is_used_until_edited_by_hand() {
            open(460, 460, 1, "opal", [])
            const sw = ({ id: "t9", name: "brand", entry: ({ colour: "#123456", source: "opal", params: { speed: 0 } }) })
            picker.applySwatch(sw.id, sw.entry, true)
            wait(30)
            compare(picker.entryFrom, "t9")
            compare(picker.currentValue().from, "t9", "the role carries the swatch it uses")
            picker.loadOnWheel(Qt.color("#ff0000")); picker.livePreview()   // what a drag on the wheel does
            wait(30)
            compare(picker.entryFrom, "", "edited by hand: its own now")
            picker.applySwatch(sw.id, sw.entry, true); wait(30)
            picker.applyText("#00ff00")
            compare(picker.entryFrom, "", "typed: its own now")
            picker.applySwatch(sw.id, sw.entry, true); wait(30)
            picker.applyText("#00ff00s0f804000")
            compare(picker.entryFrom, "", "pasted: its own now")
            picker.applySwatch(sw.id, sw.entry, true); wait(30)
            const st = shelf().stamped(picker.currentValue(), "t9")
            compare(st.from, "t9")
            compare(Theme.colorOf(st, "#000000").toString(), "#123456")
            compare(shelf().stamped("#abcdef", "t9").colour, "#abcdef")
            mouseClick(part("pickerAccept"))
            compare(committed.from, "t9")
        }

        // A theme travels with the swatches its own roles were stamped with,
        // so on another machine the shelf they came from is not needed. They
        // land here read-only beside the profile's, and promoting one COPIES
        // it — the theme keeps its own and stays complete on its own.
        function test_a_themes_swatches_are_promoted_by_copying() {
            open(460, 460, 1, "opal", [])
            openShelf()
            shelf().swatches = []
            const fromTheme = ({ id: "t1", name: "shipped",
                                 entry: ({ colour: "#123456", source: "opal" }) })
            shelf().promote(fromTheme)
            compare(shelf().swatches.length, 1)
            compare(shelf().swatches[0].name, "shipped")
            verify(shelf().swatches[0].id !== "t1",
                   "an id of its own: editing the copy must not read as editing the theme's")
            compare(Theme.sourceOf(shelf().swatches[0].entry), "opal")
            verify(shelf().hasByName("shipped"))
            shelf().visible = false
        }

        // A swatch can be added to the theme directly. With no ThemeBackend
        // here, the controls must be reachable and the two writes no-ops; the
        // list arithmetic is checked directly.
        function test_the_theme_section_offers_add_and_remove() {
            open(460, 460, 1, "opal", [])
            openShelf()
            const bodyItem = findChild(shelf(), "swatchShelfBody")
            verify(shelf().themeSection, "open, so the theme's section is there to add into")
            verify(findChild(bodyItem, "themeSwatchAdd") !== null)
            verify(findChild(bodyItem, "themeSwatchName") !== null)
            // no backend: naming one changes nothing and raises nothing
            shelf().addToTheme("brand")
            compare(shelf().themeSwatches.length, 0)
            shelf().dropFromTheme("whatever")
            compare(shelf().themeSwatches.length, 0)
            // an empty name is refused before the backend is asked
            shelf().addToTheme("   ")
            compare(shelf().themeSwatches.length, 0)
            shelf().visible = false
        }

        // the arithmetic both removes run on
        function test_a_list_loses_only_the_id_named() {
            const list = [({ id: "a" }), ({ id: "b" }), ({ id: "c" })]
            compare(shelf().withoutId(list, "b").length, 2)
            compare(shelf().withoutId(list, "b")[1].id, "c")
            compare(shelf().withoutId(list, "gone").length, 3)
            compare(list.length, 3, "the list it was given is not the one it changed")
        }

        function test_a_swatch_is_dropped() {
            open(460, 460, 1, "opal", [])
            openShelf()
            shelf().swatches = []
            shelf().add("one"); shelf().add("two")
            compare(shelf().swatches.length, 2)
            shelf().drop(shelf().swatches[0].id)
            compare(shelf().swatches.length, 1)
            compare(shelf().swatches[0].name, "two")
            shelf().visible = false
        }

        // An entry whose stamp names a swatch nobody has still renders: the
        // entry carries its own value, and the stamp is only a label.
        function test_a_stamp_naming_nothing_is_harmless() {
            picker.open({ colour: "#112233", source: "opal", params: { speed: 0 },
                          from: "gone-forever" },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            compare(picker.entryFrom, "gone-forever")
            compare(Theme.sourceOf(picker.currentValue()), "opal")
            compare(Theme.rolesFrom("gone-forever").length, 0)
            mouseClick(part("pickerAccept"))
            compare(committed.from, "gone-forever", "and it rides back out untouched")
        }

        // ---- per-layer blend ----
        function test_blend_is_per_layer() {
            open(460, 460, 1, "opal", [])
            picker.blendMode = "multiply"
            picker.addLayer()
            compare(picker.blendMode, "normal", "a new layer does not inherit the one below")
            picker.blendMode = "screen"
            mouseClick(part("pickerAccept"))
            compare(committed.layers[0].blend, "multiply")
            compare(committed.layers[1].blend, "screen")
            // the bottom layer's is the entry's: it is what the whole stack
            // meets the surface behind it with, and BlendSurface reads it
            compare(Theme.blendOf(committed), "multiply")
            // and a code carries both
            const back = Theme.codeToEntry(Theme.entryToCode(committed))
            compare(Theme.layersOf(back)[0].blend, "multiply")
            compare(Theme.layersOf(back)[1].blend, "screen")
        }

        // The bottom layer's blend is the entry's (how the whole stack meets
        // the window behind it), and nothing captures that, so it can only be
        // one of the GPU's blend factors. A layer above it meets the layers
        // under it, which ARE ours, so every mode is available there.
        function test_the_bottom_layer_is_limited_to_what_the_gpu_can_do() {
            open(460, 460, 1, "opal", [])
            compare(picker.blendChoices.length, picker.blendModes.length)
            for (const m of picker.blendChoices)
                verify(Theme.blendIsHardware(m === "normal" ? "" : m), m + " is a blend factor")
            picker.addLayer()
            compare(picker.layerAt, 1)
            verify(picker.blendChoices.length > picker.blendModes.length)
            for (const m of ["overlay", "soft light", "difference", "hue", "luminosity", "darken"])
                verify(picker.blendChoices.indexOf(m) > 0, m + " is offered above the bottom")
            picker.blendMode = "overlay"
            mouseClick(part("pickerAccept"))
            compare(committed.layers[1].blend, "overlay")
            // and it survives a code, past what a one-nibble tag can hold
            compare(Theme.layersOf(Theme.codeToEntry(Theme.entryToCode(committed)))[1].blend, "overlay")
        }

        function test_a_mode_past_the_nibble_still_round_trips() {
            const e = ({ layers: ["#112233", ({ colour: "#445566", blend: "luminosity" })] })
            const code = Theme.entryToCode(e)
            verify(code.indexOf("n10") > 0, "a two-digit tag past fifteen: " + code)
            compare(Theme.layersOf(Theme.codeToEntry(code))[1].blend, "luminosity")
            // ...and the ones inside it keep the tag every saved code uses
            const old = Theme.entryToCode({ layers: ["#112233", ({ colour: "#445566", blend: "screen" })] })
            verify(old.indexOf("b2") > 0, old)
        }

        // ---- mask mode, and solo ----
        function test_a_layer_is_confined_to_the_edge_or_the_interior() {
            open(460, 520, 1, "opal", [])
            picker.addLayer()
            compare(picker.layerMask, "all")
            verify(!findChild(part("pickerEditor"), "pickerLever_layerMaskDist"),
                   "no band to set while the layer covers everything")
            mouseClick(findChild(part("pickerEditor"), "pickerMask_edge"))
            wait(20)
            compare(picker.layerMask, "edge")
            const band = findChild(part("pickerEditor"), "pickerLever_layerMaskDist")
            verify(band, "a band appears once there is one")
            band.apply(6)
            mouseClick(part("pickerAccept"))
            compare(committed.layers[1].mask, "edge")
            compare(committed.layers[1].maskDist, 6)
            verify(committed.layers[0].mask === undefined, "the whole shape is not written")
            // and it survives a code
            const back = Theme.layersOf(Theme.codeToEntry(Theme.entryToCode(committed)))
            compare(back[1].mask, "edge")
            fuzzyCompare(back[1].maskDist, 6, 0.2)
        }

        function test_solo_shows_one_layer_and_commits_all_of_them() {
            picker.open({ layers: [ { colour: "#112233", source: "opal", params: { speed: 0 } },
                                    { colour: "#445566", source: "gloss", params: { speed: 0 } },
                                    { colour: "#778899" } ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            compare(picker.layerCount, 3)
            picker.selectLayer(1)
            picker.toggleSolo()
            compare(picker.soloAt, 1)
            verify(!picker.layerShown(0) && picker.layerShown(1) && !picker.layerShown(2))
            compare(Theme.sourceOf(picker.previewValue()), "gloss", "only the soloed layer is shown")
            compare(picker.currentValue().layers.length, 3, "and all three are committed")
            // muting is the same question the other way round, and clears solo
            picker.toggleMute(0)
            compare(picker.soloAt, -1)
            verify(!picker.layerShown(0) && picker.layerShown(1) && picker.layerShown(2))
            picker.toggleSolo()
            picker.toggleSolo()
            compare(picker.soloAt, -1, "and it toggles off")
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 3)
        }

        // ---- the layout ----
        // The stack spans the whole entry. The colour column holds the colour
        // and its palette stops; the layer column holds the selected layer's
        // fill, levers, mask and blend.
        function under(ancestor, item) {
            let p = item
            while (p) { if (p === ancestor) return true; p = p.parent }
            return false
        }
        // The stack is a list, down the left; everything the selected layer IS
        // goes down the right, its colour with it, since a colour is one of a
        // layer's properties.
        function test_the_rail_is_the_stack_and_the_pane_is_the_layer() {
            open(560, 620, 1, "lucent", stops)
            const rail = part("pickerLayers")
            const pane = part("pickerFill").parent
            verify(rail !== pane)
            verify(under(rail, part("pickerLayer_0")), "the stack is in the rail")
            verify(under(rail, part("pickerLayerTools")))
            verify(under(rail, part("pickerCost")))
            for (const n of ["saturationValue", "hueStrip", "alphaStrip", "paletteStops",
                             "pickerFill", "pickerBlends", "pickerMask", "pickerSpace"])
                verify(under(pane, part(n)), n + " is the layer's")
            verify(under(pane, findChild(part("pickerEditor"), "pickerLever_stSpeed")))
        }

        // What acts on the stack sits under it. The rows grow from the
        // top and the buttons stay at the foot of the rail, which is the only
        // place they hold still while layers are added and removed.
        function test_the_rail_tools_are_at_its_foot() {
            open(560, 620, 1, "lucent", stops)
            const rail = part("pickerLayers")
            const tools = part("pickerLayerTools")
            const rows = findChild(rail, "pickerLayer_0").parent
            const foot = tools.parent
            verify(rows.y < foot.y, "the stack is above what acts on it")
            verify(Math.abs((foot.y + foot.height) - rail.height) < 1,
                   "and the buttons are AT the foot: " + (foot.y + foot.height) + " of " + rail.height)
            // a layer added grows the list downwards and the buttons stay put
            // against the bottom, rather than being pushed along by it
            const gapBefore = foot.y - (rows.y + rows.height)
            picker.addLayer(); wait(30)
            verify(Math.abs((foot.y + foot.height) - rail.height) < 1, "still at the foot")
            verify(foot.y - (rows.y + rows.height) < gapBefore, "the list grew into the space")
        }

        // The footer is at the bottom of the window, not at the bottom of a
        // block of content that stops short of it. The window follows its
        // content, so at its own size there is nothing spare, but it can be
        // dragged taller.
        function test_the_footer_and_the_rail_reach_the_real_bottom() {
            open(560, 620, 1, "lucent", stops)
            const area = part("pickerFooter").parent
            const footer = part("pickerFooter")
            picker.height = picker.height + 220   // as a drag on the frame would
            wait(40)
            verify(Math.abs((footer.y + footer.height) - area.height) < 1,
                   "the footer is at the foot: " + (footer.y + footer.height) + " of " + area.height)
            const rail = part("pickerLayers"), tools = part("pickerLayerTools").parent
            verify(Math.abs((rail.y + rail.height) - (footer.y - Theme.gap(6))) < 2,
                   "and the rail reaches down to it")
            verify(Math.abs((tools.y + tools.height) - rail.height) < 1,
                   "so its buttons land at the real bottom")
        }

        // Top layer first, because the row above draws over the row below.
        function test_the_rail_reads_top_layer_first() {
            picker.open({ layers: [ { colour: "#112233", source: "opal", params: { speed: 0 } },
                                    { colour: "#445566", source: "gloss", params: { speed: 0 } } ] },
                        ({ commit: v => committed = v, blend: true, adaptive: true }))
            wait(30)
            const rows = []
            for (const c of findChild(part("pickerLayers"), "pickerLayer_0").parent.children)
                if (String(c.objectName).indexOf("pickerLayer_") === 0) rows.push(c)
            compare(rows.length, 2)
            verify(rows[0].y < rows[1].y)
            compare(rows[0].at, 1, "the top of the list is the top of the stack")
            compare(rows[1].at, 0)
            // and the arrows mean what they point at
            picker.selectLayer(0)
            picker.moveLayer(1)
            compare(Theme.sourceOf(picker.layerEntries()[1]), "opal", "up the list is up the stack")
        }

        // Seventeen chips is six rows of them in a column that also holds four
        // sliders. A list that long is a list.
        function test_blend_is_a_select_not_a_wall_of_chips() {
            open(520, 560, 1, "lucent", stops)
            picker.addLayer()
            wait(20)
            verify(picker.blendChoices.length > 15)
            const sel = findChild(part("pickerBlends"), "pickerBlendSelect")
            verify(sel && sel.visible, "one control, whatever the list is worth")
            compare(part("pickerBlends").height, Theme.ctl(24), "one row high")
        }

        // Three looks, not three fixes for the same thing.
        function test_the_anchor_is_set_and_committed() {
            open(520, 560, 1, "opal", [])
            compare(picker.layerSpace, "window", "what a fill always did")
            verify(part("pickerSpace").visible, "a pattern has somewhere to be anchored")
            mouseClick(findChild(part("pickerEditor"), "pickerSpace_item"))
            wait(20)
            compare(picker.layerSpace, "item")
            mouseClick(part("pickerAccept"))
            compare(committed.space, "item")
            compare(Theme.layersOf(committed)[0].space, "item")
            compare(Theme.codeToEntry(Theme.entryToCode(committed)).space, "item")
        }

        // A flat colour and a contrast look the same wherever they are
        // measured from, so there is nothing to anchor and no control for it.
        function test_a_kind_with_no_pattern_has_no_anchor() {
            open(520, 560, 1, "colour", [])
            verify(!part("pickerSpace").visible)
        }

        // What was made lately: an accept remembers the entry, newest first,
        // one of each, five at most — the swatch's right-click in settings.
        function test_the_last_five_entries_are_remembered() {
            picker.recents = []
            const codes = ["#101010", "#202020", "#303030", "#404040", "#505050", "#606060"]
            for (const c of codes) {
                open(460, 460, 1, "colour", [])
                picker.applyText(c)
                mouseClick(part("pickerAccept"))
            }
            compare(picker.recents.length, 5, "five at most")
            compare(Theme.entryToCode(picker.recents[0]), "#606060", "newest first")
            compare(Theme.entryToCode(picker.recents[4]), "#202020", "the oldest fell off")
            open(460, 460, 1, "colour", [])
            picker.applyText("#404040")
            mouseClick(part("pickerAccept"))
            compare(picker.recents.length, 5, "one of each")
            compare(Theme.entryToCode(picker.recents[0]), "#404040", "made again is first again")
            compare(Theme.entryLabel(picker.recents[0]), "#404040")
            compare(Theme.entryLabel({ layers: ["#3060ff", ({ source: "opal" }), ({ source: "pixelate" })] }),
                    "#3060ff + opal + pixelate")
            picker.recents = []
        }

        // Auto or literal is a toggle, and the row under it is the one the
        // toggle names: a percentage in auto, pixels in literal
        function test_an_edge_is_auto_by_percent_or_literal_in_pixels() {
            open(560, 620, 1, "bevel", stops)
            const fo = findChild(picker, "fillSettings")
            fo.openBeside(); wait(40)
            const body = findChild(fo, "fillSettingsBody")
            verify(findChild(body, "fillOption_edgeAuto").visible, "the toggle")
            verify(findChild(body, "fillOption_edgeScale").visible, "auto: the percentage")
            verify(!findChild(body, "fillOption_edge").visible, "not the pixels")
            mouseClick(findChild(body, "fillToggle_edgeAuto_0")); wait(20)
            compare(picker.optionOf("edgeAuto"), 0)
            verify(findChild(body, "fillOption_edge").visible, "literal: the pixels")
            verify(!findChild(body, "fillOption_edgeScale").visible, "not the percentage")
            picker.setOption("edge", 12)
            mouseClick(part("pickerAccept"))
            compare(Number(Theme.styledOf(committed).own.edge), 12)
            compare(Number(Theme.styledOf(committed).own.edgeAuto), 0)
            fo.visible = false
        }

        // ---- filters: a layer that changes the layers under it ----
        // Nothing of its own (no colour, no levers, no anchor, no blend), only
        // its options; and nothing to offer where nothing is under it.
        function test_a_filter_is_only_offered_above_the_bottom() {
            open(560, 620, 1, "opal", [])
            openSel()
            verify(!sel().filtersApply, "the bottom layer has nothing under it")
            verify(sel().kinds.indexOf("pixelate") < 0, "so no filter is offered")
            verify(!selPart("fillFilter_filter").visible, "and no chip to ask for one")
            sel().visible = false
            picker.addLayer(); wait(20)
            openSel()
            verify(sel().filtersApply)
            verify(sel().kinds.indexOf("pixelate") >= 0, "a layer with something under it may filter it")
            verify(selPart("fillFilter_filter").visible)
            mouseClick(selPart("fillFilter_filter")); wait(20)
            for (const k of sel().kinds) verify(Theme.isFilter(k), k + " is a filter")
            verify(sel().under !== null, "and each tile shows the filter over the layer below")
            compare(Theme.sourceOf(sel().under), "opal")
            picker.layerAt = 0; wait(20)
            verify(!sel().onlyFilter, "the chip lets go with the layer that could use it")
            verify(sel().kinds.indexOf("opal") >= 0, "and the gallery is whole again")
            sel().visible = false
        }

        function test_a_filter_layer_has_only_its_options() {
            open(560, 620, 1, "opal", [])
            picker.addLayer(); wait(20)
            picker.sourceMode = "posterize"
            verify(picker.isFilterKind)
            verify(!picker.styled && !picker.needsColour, "no colour to pick")
            verify(!part("saturationValue").visible)
            for (const l of picker.levers) verify(l.key.indexOf("st") !== 0, "no fill lever: " + l.key)
            verify(!part("pickerSpace").visible, "nothing to anchor: it has no pattern")
            verify(!part("pickerBlends").visible, "no blend: it replaces what is under it")
            verify(part("pickerMask").visible, "but it can be confined to the edge or the interior")
            verify(part("pickerFillSettings").visible, "and its options are what it is")
            compare(part("pickerFillName").text, "posterize")
            settings().openBeside(); wait(40)
            optRow("levels").apply(2); wait(20)
            settings().visible = false
            mouseClick(part("pickerAccept"))
            compare(committed.layers.length, 2)
            compare(committed.layers[1].source, "posterize")
            compare(committed.layers[1].params.levels, 2)
            compare(Theme.stackPasses(committed), 3,
                    "a filter rung has no fill to render first, and the bottom layer no rung: 1 + 1 + 1")
            // and a code carries the kind and its options
            const back = Theme.layersOf(Theme.codeToEntry(Theme.entryToCode(committed)))
            compare(back[1].source, "posterize")
            compare(back[1].params.own.levels, 2)
        }

        function test_a_filters_thumbnail_shows_it_over_the_layer_below() {
            open(560, 620, 1, "opal", [])
            picker.addLayer(); wait(20)
            picker.sourceMode = "invert"; wait(20)
            const chip = findChild(part("pickerLayer_1"), "") // the row's chip is its first EntryChip
            const face = part("pickerLayer_1").children.filter(c => c.under !== undefined)[0]
            verify(face, "the rail row draws the layer through an EntryChip")
            verify(face.under !== null, "with the layer below as what it filters")
            compare(Theme.sourceOf(face.under), "opal")
            verify(face.filterAlone)
        }

        function test_plain_picker_and_cancel() {
            let preview = null
            picker.open("#315080", ({ commit: v => committed = v, preview: v => preview = v }))
            picker.width = 400; picker.height = 380
            wait(30)
            verify(!part("pickerFill").visible)
            inside(part("pickerAccept"))
            picker.loadOnWheel(Qt.color("#ff0000"))
            picker.livePreview()
            wait(50)
            compare(preview, "#ff0000")
            picker.reject()
            compare(preview, "#315080")
            compare(committed, null)
        }
    }
}
