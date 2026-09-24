pragma Singleton
import QtQuick

// Quantized session clock for the GPU background shaders. 33ms buckets (the
// same tick as BackgroundItem's absT) so the full and mini instances render
// IDENTICAL frames; epoch-relative because float32 uniforms can't hold epoch
// milliseconds. One singleton = one epoch for both windows.
QtObject {
    readonly property real epoch: Math.floor(Date.now() / 33) * 0.033
    function now() { return Math.floor(Date.now() / 33) * 0.033 - epoch }
}
