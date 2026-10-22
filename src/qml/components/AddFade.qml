import QtQuick

// An item view's add transition: the row runs the fade and the transition ends
// at once, because a view does not move a row while its transition runs.
Transition {
    id: t
    property int duration: 150
    readonly property Component fade: Component {
        NumberAnimation {
            property: "opacity"; from: 0; to: 1
            onStopped: destroy()
        }
    }
    ScriptAction {
        script: {
            const it = t.ViewTransition.item
            if (it) t.fade.createObject(it, { target: it, duration: t.duration, running: true })
        }
    }
}
