#pragma once
#include <memory>
#include <string>
#include <vector>
#include <cstddef>

// Pimpl so projectM headers stay OUT of the rest of the app. ProjectMWrapper.cpp
// is the ONLY translation unit touching projectM — it holds both the v3 (C++) and
// v4 (C API) backends, selected by the USE_PROJECTM4 compile definition.
class ProjectMWrapper {
public:
    // MUST be constructed with a current GL context (ctor compiles shaders).
    ProjectMWrapper(int fbWidth, int fbHeight,
                    const std::string& presetDir, const std::string& dataDir);
    ~ProjectMWrapper();

    void resize(int fbWidth, int fbHeight);   // -> projectM_resetGL (framebuffer pixels)
    void renderFrame();                       // GL thread only
    void nextPreset();
    void prevPreset();
    void playPresetAt(int index);             // playlist position (hard cut)
    std::vector<std::string> presetPaths() const;   // full playlist, playlist order
    int  lastSwitchedPreset() const;                // playlist index of the latest switch (-1 none)
    void feedPcm(const float* interleaved, std::size_t floatCount);  // GL thread only
    int  playlistSize() const;

    // live settings (GL thread — call from render()). presetDuration<=0
    // effectively disables auto-cycle (very long duration).
    void setBeatSensitivity(float s);
    void setPresetDuration(double seconds);
    void setShuffle(bool on);
    void setPresetLocked(bool locked);

private:
    struct Impl;
    Impl* impl_ = nullptr;
};
