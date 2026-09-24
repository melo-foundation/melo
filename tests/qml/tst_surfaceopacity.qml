import QtQuick
import QtTest
import "../../src/qml"
import "../../src/qml/components"

// A role's opacity has to reach what draws it. The colour's alpha cannot
// carry it: that alpha is the layer's own, and for a stack it is the bottom
// layer's. Every surface in a themed melo is styled, so without this the
// master opacity slider would write a value nothing reads.
Item {
    width: 200; height: 120
    Surface { id: surf; anchors.fill: parent; role: "window" }
    Surface { id: plain; width: 10; height: 10; role: "card" }
    Surface { id: flipper; width: 10; height: 10 }
    StyledFill { id: stackFill; width: 10; height: 10 }

    TestCase {
        name: "SurfaceOpacity"
        when: windowShown
        function initTestCase() { Theme.held = true }
        function cleanupTestCase() {
            delete Theme.p.window; delete Theme.p.card; delete Theme.p.hover; delete Theme.ts.opacity
            Theme.pChanged(); Theme.tsChanged(); Theme.held = false
        }
        function setOpacity(role, v) {
            const o = {}
            for (const k in Theme.opacityMap) o[k] = Theme.opacityMap[k]
            o[role] = v
            Theme.ts.opacity = o
            Theme.tsChanged()
        }

        function test_a_styled_surface_carries_its_roles_opacity() {
            Theme.p.window = ({ colour: "#3060ff", source: "opal", params: ({ speed: 0 }) })
            Theme.pChanged()
            verify(surf.styled, "a fill draws this, not the flat rectangle")
            setOpacity("window", 1)
            compare(surf.fillOpacity, 1)
            setOpacity("window", 0.3)
            compare(surf.fillOpacity, 0.3, "the value the master opacity slider writes")
        }

        // ...and a stack, where the colour's alpha is a LAYER's and cannot
        // carry the role's opacity for it
        function test_a_stacked_surface_carries_it_too() {
            Theme.p.window = ({ layers: ["#1c0e15",
                                         ({ colour: "#3060ff", source: "opal", params: ({ speed: 0 }) })] })
            Theme.pChanged()
            verify(surf.styled)
            setOpacity("window", 0.45)
            compare(surf.fillOpacity, 0.45)
            // the flat colour path still folds it in
            compare(Math.round(surf.color.a * 100) / 100, 0.45,
                    "a plain rectangle paints it through the colour instead")
        }

        // A hover does not rebuild a fill. A row flips its role between "" and
        // "hover" on every crossing; where one of the two is layered, a rebuild
        // would build and tear down a whole fill chain twice a row.
        function test_a_surface_keeps_the_fill_it_built() {
            Theme.p.hover = ({ colour: "#3060ff", source: "opal", params: ({ speed: 0 }) })
            Theme.pChanged()
            flipper.role = "hover"
            verify(flipper.blending, "a fill draws this")
            verify(flipper.everBlended)
            flipper.role = ""
            verify(!flipper.blending, "the plain rectangle draws it at rest")
            verify(flipper.everBlended, "and what it built is still there")
            delete Theme.p.hover
            Theme.pChanged()
        }

        // A stack is one picture. Item opacity is applied per node, so at
        // anything under 1 each layer would be drawn at it and the one below
        // would show through the one above.
        function test_a_translucent_stack_is_flattened_first() {
            // a top layer you can see through: the one below it shows, so the
            // stack has to become one picture before the opacity is applied
            stackFill.layers = [({ colour: "#ff00ff" }), ({ colour: "#000000", opacity: 0.6 })]
            stackFill.opacity = 1
            verify(!stackFill.layer.enabled, "opaque: nothing can show through, so no render target")
            stackFill.opacity = 0.5
            verify(stackFill.layer.enabled, "rendered once, and the opacity applied to that")
            stackFill.layers = [({ colour: "#ff00ff" })]
            verify(!stackFill.layer.enabled, "one layer has nothing under it to show through")
            stackFill.opacity = 1
        }

        // A layer under an opaque one is never drawn, does not flatten the
        // stack, and does not start the clock.
        function test_an_opaque_layer_hides_what_is_under_it() {
            const covered = [({ source: "gradient", colour: "#ff00ff", params: ({ speed: 1 }) }),
                             ({ colour: "#000000" })]
            compare(Theme.coveredBelow(Theme.layersOf(({ layers: covered }))), 1)
            verify(!Theme.entryMoves(({ layers: covered })), "an animation nobody can see is not one")
            stackFill.layers = covered
            stackFill.opacity = 0.5
            verify(!stackFill.layer.enabled, "one drawn layer needs no render target")
            // ...and every reason it might NOT cover
            for (const notCover of [({ colour: "#000000", opacity: 0.9 }),
                                    ({ colour: "#00000080" }),
                                    ({ colour: "#000000", mask: "edge" }),
                                    ({ colour: "#000000", blend: "multiply" }),
                                    ({ source: "gradient", colour: "#000000" })]) {
                const ls = Theme.layersOf(({ layers: [covered[0], notCover] }))
                compare(Theme.coveredBelow(ls), 0, JSON.stringify(notCover) + " covers nothing")
            }
            stackFill.layers = null
            stackFill.opacity = 1
        }

        function test_a_role_without_one_takes_the_master() {
            Theme.p.card = ({ colour: "#204060" })
            Theme.ts.opacity = ({})
            Theme.ts.opacityScale = 0.6
            Theme.tsChanged()
            compare(plain.fillOpacity, 0.6, "what a surface with no value of its own gets")
            delete Theme.ts.opacityScale
            Theme.tsChanged()
        }
    }
}
