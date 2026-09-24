// Cross-window state root. Not named Plugin.qml: QML registers each .qml file
// as a type of its name, which would shadow the injected `Plugin` object in
// ui/Main.qml, and the shell rejects that name.
import QtQuick

QtObject {
    id: entry

    // `action` settings fields invoke a same-named signal on this root.
    signal resetAccent()
    onResetAccent: MeloUi.settings.set("accent", "green")

    // read by ui/Main.qml as Plugin.accentColor
    readonly property color accentColor:
        MeloUi.settings.values.accent === "blue" ? "#4f9cff"
      : MeloUi.settings.values.accent === "red"  ? "#ff5f56"
                                                 : "#42d17a"
}
