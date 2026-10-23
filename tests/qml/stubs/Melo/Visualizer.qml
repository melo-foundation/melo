import QtQuick

// a stand-in for melo's C++ type, so a test can load Main.qml
Item {
    property var presetNames
    property var currentPreset
    function nextPreset() { return undefined }
    function prevPreset() { return undefined }
    function playPresetAt(i) { return undefined }
    function setBeatSensitivity(s) { return undefined }
    function setPresetDuration(s) { return undefined }
    function setShuffle(on) { return undefined }
    function setPresetLocked(on) { return undefined }
    function setPlaying(on) { return undefined }
    function setPresetNames(names) { return undefined }
    function setCurrentPresetIndex(i) { return undefined }
}
