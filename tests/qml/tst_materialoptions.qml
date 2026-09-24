import QtQuick
import QtTest
import "../../src/qml"

Item {
    TestCase {
        name: "MaterialOptions"
        readonly property var oldOrder: ({
            toon: ["ink", "relief", "edge", "edgeAuto", "edgeScale"],
            bevel: ["edge", "edgeAuto", "edgeScale"], cloud: ["puff"]
        })
        function test_slots_and_order() {
            for (const kind of Object.keys(oldOrder)) {
                const options = Theme.fillOptions(kind), used = ({})
                compare(options.length, 8)
                compare(options.slice(0, oldOrder[kind].length).map(o => o.name), oldOrder[kind], "append-only code order")
                for (const o of options) {
                    verify(o.slot >= 0 && o.slot < 8 && !used[o.slot], kind + ": unique uniform slot for " + o.name)
                    used[o.slot] = true
                    verify(o.value >= Theme.optFrom(o) && o.value <= Theme.optTo(o), kind + ": default in range")
                }
            }
        }
        function test_old_codes_data() {
            // Saved before the extra controls existed, with nondefault old
            // values. Reordering a table silently reinterprets these bytes.
            return [
                { tag: "toon", kind: "toon", code: "#789ac4s1ca620000k5493e1b0066",
                  expected: { ink: 1.15, relief: 0.55, edge: 3, edgeAuto: 0, edgeScale: 175 } },
                { tag: "bevel", kind: "bevel", code: "#789ac4s16a620000k3160066",
                  expected: { edge: 2.5, edgeAuto: 0, edgeScale: 175 } },
                { tag: "cloud", kind: "cloud", code: "#789ac4s1ba620000k166", expected: { puff: 6.2 } }
            ]
        }
        function atSlot(kind, params, slot) {
            const v = Theme.optionVec(kind, params, slot < 4 ? 0 : 4)
            return [v.x, v.y, v.z, v.w][slot % 4]
        }
        function test_old_codes(data) {
            const entry = Theme.codeToEntry(data.code), params = Theme.styledOf(entry)
            compare(Theme.sourceOf(entry), data.kind)
            for (const o of Theme.fillOptions(data.kind)) {
                const expected = data.expected[o.name]
                if (expected !== undefined)
                    fuzzyCompare(atSlot(data.kind, params, o.slot), expected, (Theme.optTo(o) - Theme.optFrom(o)) / 255 + 0.001, o.name)
                else {
                    verify(params.own[o.name] === undefined, "old code did not carry " + o.name)
                    fuzzyCompare(atSlot(data.kind, params, o.slot), o.value, 0.0001, "new control defaults: " + o.name)
                }
            }
        }
        function test_new_options_round_trip() {
            for (const kind of Object.keys(oldOrder)) {
                for (const end of ["low", "high"]) {
                    const own = ({})
                    for (const o of Theme.fillOptions(kind)) own[o.name] = end === "low" ? Theme.optFrom(o) : Theme.optTo(o)
                    const entry = { source: kind, colour: "#789ac4", params: { speed: 0, own: own } }
                    const code = Theme.entryToCode(entry), restored = Theme.codeToEntry(code)
                    compare(Theme.entryToCode(restored), code)
                    const params = Theme.styledOf(restored)
                    for (const o of Theme.fillOptions(kind))
                        fuzzyCompare(atSlot(kind, params, o.slot), own[o.name], 0.001, kind + ": " + o.name)
                }
            }
        }
    }
}
