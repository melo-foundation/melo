import QtQuick

Rectangle {
    id: root
    color: "#202020"
    radius: 6
    border.color: Plugin.accentColor
    border.width: 1

    // Drag the window by its background. The shell owns the geometry; a plugin
    // only ever asks (MeloUi.window.<id>.startDrag()).
    MouseArea {
        anchors.fill: parent
        onPressed: MeloUi.window.main.startDrag()
    }

    component Btn: Text {
        signal activated()
        color: btnMa.containsMouse ? Plugin.accentColor : "white"
        font.pixelSize: 18
        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            onClicked: parent.activated()
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 6

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // .values.<key>, not .get() — a method call is not a reactive binding
            visible: MeloUi.settings.values.showTitle === true
            width: root.width - 24
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: "white"
            font.pixelSize: 12
            text: MeloUi.player.hasTrack ? MeloUi.player.title : "nothing playing"
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 14

            Btn {
                text: MeloUi.player.playing ? "⏸" : "▶"
                onActivated: MeloUi.player.playing ? MeloUi.player.pause()
                                                   : MeloUi.player.play()
            }
            Btn { text: "⏭"; onActivated: MeloUi.player.next() }
            Btn { text: "⚙"; onActivated: MeloUi.app.openPluginSettings() }
            // hides every window this plugin owns
            Btn { text: "✕"; onActivated: MeloUi.app.exitMiniMode() }
        }
    }
}
