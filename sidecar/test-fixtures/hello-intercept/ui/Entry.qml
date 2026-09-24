import QtQuick
QtObject {
    function intercept(id) {
        if (id !== "play")
            return
        if (MeloUi.settings.values.swallowPlay)
            return
        MeloUi.player.play()
    }
}
