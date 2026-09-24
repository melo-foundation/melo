import QtQuick
import QtTest

// ScrollText colours its label with `Theme[root.ink]` inside a Binding, which
// recolours only if the engine records a dependency on the property a name
// lookup resolves to. Pins that Qt premise.
Item {
    QtObject {
        id: src
        property color text: "#111111"
        property color textDim: "#222222"
    }
    property string ink: "text"
    Rectangle { id: label; width: 4; height: 4 }
    Binding { target: label; property: "color"; value: src[ink]; when: ink.length > 0 }

    TestCase {
        name: "DynamicLookup"
        function test_a_named_lookup_follows_the_property() {
            compare(label.color.toString(), "#111111")
            src.text = "#aaaaaa"
            compare(label.color.toString(), "#aaaaaa",
                    "src[ink] did not track src.text — a Binding through a dynamic "
                    + "lookup is no longer reactive, and ScrollText.ink needs a different wiring")
        }
        function test_changing_the_name_switches_property() {
            ink = "textDim"
            compare(label.color.toString(), "#222222")
            src.textDim = "#bbbbbb"
            compare(label.color.toString(), "#bbbbbb")
        }
    }
}
