import QtQuick
import QtQuick.Window
import ".."

// What readers of the ground `base` sample while a GroundPicture of its window is shown:
// the ground's texture with the pictures over it, where they are. Rendered for its
// layer behind a zero-sized clip, never drawn: the ground on screen stays as it was.
// A sibling after the ground, over the same rect; inside it, it would read itself.
// The copies are placed at rest (slow tick, size and place changes), as readers are.
Item {
    id: host
    required property Item base
    // the item a reader of `base` samples; it never depends on the ground's layer,
    // which its readers switch on
    readonly property Item texture: here > 0 ? tex : base
    readonly property bool active: base.layer.enabled && here > 0
    readonly property int here: {
        const w = host.Window.window
        let n = 0
        for (const p of Theme.groundPictures) if (p.Window.window === w) n++
        return n
    }
    width: 0; height: 0
    clip: true
    // set, not bound: finding it can build the window's FillCache, a binding loop
    property Item blank: null
    Component.onCompleted: blank = Theme.blankFor(Window.window)
    Window.onWindowChanged: blank = Theme.blankFor(Window.window)
    Item {
        id: tex
        width: host.base.width; height: host.base.height
        layer.enabled: host.active
        ShaderEffect {
            anchors.fill: parent
            visible: host.active
            // hidden, it still syncs: the window's blank, never null
            property variant source: host.active ? host.base : host.blank
        }
        Repeater {
            model: host.active ? Theme.groundPictures : []
            ShaderEffect {
                id: copy
                required property Item modelData
                // A ShaderEffect reads only items in its own window
                readonly property bool mine: modelData !== null && modelData.Window.window === host.Window.window
                                             && modelData.layer.enabled
                visible: mine
                property variant source: mine ? modelData : host.blank
                opacity: mine ? modelData.opacity : 0
                function place() {
                    if (!mine) return
                    const p = modelData.mapToItem(tex, 0, 0)
                    x = p.x; y = p.y
                    width = modelData.width; height = modelData.height
                }
                onMineChanged: place()
                Component.onCompleted: place()
                Connections {
                    target: copy.mine ? copy.modelData : null
                    function onXChanged() { copy.place() }
                    function onYChanged() { copy.place() }
                    function onWidthChanged() { copy.place() }
                    function onHeightChanged() { copy.place() }
                }
                Connections {
                    target: Theme
                    enabled: copy.mine
                    function onSlowTickChanged() { copy.place() }
                }
            }
        }
    }
}
