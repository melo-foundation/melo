#include "ProjectMWrapper.h"

#include <cstdlib>
#include <cstdio>

#ifdef USE_PROJECTM4
// ---------------------------------------------------------------- projectM 4 (C API)
#include <projectM-4/projectM.h>
#include <projectM-4/playlist.h>

#include <atomic>

struct ProjectMWrapper::Impl {
    projectm_handle pm = nullptr;
    projectm_playlist_handle pl = nullptr;
    std::atomic<int> lastSwitched{-1};   // playlist index from the switch callback
};

static void onPresetFailed(const char* file, const char* message, void*) {
    static std::atomic<int> reported{0};
    const int n = reported.fetch_add(1);
    if (n < 5)
        std::fprintf(stderr, "[pm4] preset failed: %s: %s\n",
                     file ? file : "(unnamed)", message ? message : "(no message)");
    else if (n == 5)
        std::fprintf(stderr, "[pm4] preset failures continue — silencing the rest. If every "
                             "preset fails, the visualiser draws nothing at all.\n");
}
// user_data = &Impl::lastSwitched (Impl itself is class-private)
void onPresetSwitched(bool /*is_hard_cut*/, unsigned int index, void* user) {
    static_cast<std::atomic<int>*>(user)->store((int)index);
}

ProjectMWrapper::ProjectMWrapper(int fbWidth, int fbHeight,
                                 const std::string& presetDir, const std::string& /*dataDir*/)
    : impl_(new Impl) {
    // projectm_create() returns NULL when the GL is insufficient, and any call
    // on it would segfault the render thread. This is the second half of
    // main.cpp's OpenGL 3.3 probe, for cases the probe cannot see.
    impl_->pm = projectm_create();   // requires current GL context
    if (!impl_->pm) {
        std::fprintf(stderr, "[pm4] projectm_create() failed — this GL context is not sufficient; "
                             "the visualizer will not render\n");
        return;
    }
    projectm_set_window_size(impl_->pm, (size_t)fbWidth, (size_t)fbHeight);
    projectm_set_mesh_size(impl_->pm, 48, 32);
    projectm_set_fps(impl_->pm, 60);
    projectm_set_preset_duration(impl_->pm, 30.0);
    projectm_set_soft_cut_duration(impl_->pm, 3.0);
    projectm_set_beat_sensitivity(impl_->pm, 1.0f);
    projectm_set_aspect_correction(impl_->pm, true);

    // Log failed presets: a preset whose shaders do not compile is skipped
    // silently and the frame stays black, so a build where every preset fails
    // looks healthy. Capped, since a failing pack logs thousands of lines.
    projectm_set_preset_switch_failed_event_callback(impl_->pm, &onPresetFailed, nullptr);

    impl_->pl = projectm_playlist_create(impl_->pm);
    // And again, through the playlist. projectm_playlist_create() installs its
    // own handler over the one registered above — upstream documents this in
    // playlist_callbacks.h, and says to register it after the playlist exists.
    projectm_playlist_set_preset_switch_failed_event_callback(impl_->pl, &onPresetFailed, nullptr);
    projectm_playlist_set_shuffle(impl_->pl, true);
    projectm_playlist_set_preset_switched_event_callback(impl_->pl, &onPresetSwitched,
                                                         &impl_->lastSwitched);
    const uint32_t added = projectm_playlist_add_path(impl_->pl, presetDir.c_str(),
                                                      /*recurse*/ true, /*allowDuplicates*/ false);
    std::fprintf(stderr, "[pm4] v4 engine, presets added: %u\n", added);
    if (added > 0) projectm_playlist_play_next(impl_->pl, true);
}


ProjectMWrapper::~ProjectMWrapper() {
    if (impl_->pl) projectm_playlist_destroy(impl_->pl);
    if (impl_->pm) projectm_destroy(impl_->pm);
    delete impl_;
}

void ProjectMWrapper::resize(int fbWidth, int fbHeight) {
    if (!impl_->pm) return;
    projectm_set_window_size(impl_->pm, (size_t)fbWidth, (size_t)fbHeight);
}

void ProjectMWrapper::renderFrame() {
    if (!impl_->pm) return;
    projectm_opengl_render_frame(impl_->pm);
}

void ProjectMWrapper::nextPreset() {
    if (!impl_->pm || !impl_->pl) return;
    if (impl_->pl) projectm_playlist_play_next(impl_->pl, true);
}

void ProjectMWrapper::prevPreset() {
    if (!impl_->pm || !impl_->pl) return;
    if (impl_->pl) projectm_playlist_play_previous(impl_->pl, true);
}

void ProjectMWrapper::playPresetAt(int index) {
    if (!impl_->pm || !impl_->pl) return;
    if (impl_->pl && index >= 0 && index < (int)projectm_playlist_size(impl_->pl))
        projectm_playlist_set_position(impl_->pl, (uint32_t)index, true);
}

std::vector<std::string> ProjectMWrapper::presetPaths() const {
    if (!impl_->pm || !impl_->pl) return {};
    std::vector<std::string> out;
    if (!impl_->pl) return out;
    const uint32_t n = projectm_playlist_size(impl_->pl);
    char** items = projectm_playlist_items(impl_->pl, 0, n);
    if (!items) return out;
    for (uint32_t i = 0; items[i] && i < n; ++i) out.emplace_back(items[i]);
    projectm_playlist_free_string_array(items);
    return out;
}

void ProjectMWrapper::feedPcm(const float* interleaved, std::size_t floatCount) {
    if (!impl_->pm) return;
    // v4: count = samples PER CHANNEL (frames), unlike v3's total-float count.
    projectm_pcm_add_float(impl_->pm, interleaved,
                           (unsigned int)(floatCount / 2), PROJECTM_STEREO);
}

int ProjectMWrapper::playlistSize() const {
    if (!impl_->pm || !impl_->pl) return 0;
    return impl_->pl ? (int)projectm_playlist_size(impl_->pl) : 0;
}

int ProjectMWrapper::lastSwitchedPreset() const {
    if (!impl_->pm || !impl_->pl) return 0;
    return impl_->lastSwitched.load();
}

void ProjectMWrapper::setBeatSensitivity(float s) {
    if (!impl_->pm || !impl_->pl) return;
    projectm_set_beat_sensitivity(impl_->pm, s);
}
void ProjectMWrapper::setPresetDuration(double seconds) {
    if (!impl_->pm || !impl_->pl) return;
    projectm_set_preset_duration(impl_->pm, seconds);
}
void ProjectMWrapper::setShuffle(bool on) {
    if (!impl_->pm || !impl_->pl) return;
    if (impl_->pl) projectm_playlist_set_shuffle(impl_->pl, on);
}
void ProjectMWrapper::setPresetLocked(bool locked) {
    if (!impl_->pm || !impl_->pl) return;
    projectm_set_preset_locked(impl_->pm, locked);
}

#else
// ---------------------------------------------------------------- projectM 3.x (C++ API)
#include <libprojectM/projectM.hpp>

struct ProjectMWrapper::Impl {
    projectM* pm = nullptr;
};

ProjectMWrapper::ProjectMWrapper(int fbWidth, int fbHeight,
                                 const std::string& presetDir, const std::string& dataDir)
    : impl_(new Impl) {
    projectM::Settings s;
    s.meshX = 48;
    s.meshY = 32;
    s.fps = 60;
    s.textureSize = 1024;
    s.windowWidth = fbWidth;
    s.windowHeight = fbHeight;
    s.presetURL = presetDir;
    s.datadir = dataDir;
    s.presetDuration = 30;
    s.smoothPresetDuration = 3;
    s.beatSensitivity = 1.0f;
    s.aspectCorrection = true;
    s.shuffleEnabled = true;
    s.softCutRatingsEnabled = false;

    impl_->pm = new projectM(s);   // requires current GL context
    std::fprintf(stderr, "[pm3] v3 engine, playlist: %u\n", impl_->pm->getPlaylistSize());
    if (impl_->pm->getPlaylistSize() > 0)
        impl_->pm->selectPreset(static_cast<unsigned int>(std::rand()) % impl_->pm->getPlaylistSize(), true);
}

ProjectMWrapper::~ProjectMWrapper() {
    delete impl_->pm;
    delete impl_;
}

void ProjectMWrapper::resize(int fbWidth, int fbHeight) {
    impl_->pm->projectM_resetGL(fbWidth, fbHeight);
}

void ProjectMWrapper::renderFrame() {
    impl_->pm->renderFrame();
}

void ProjectMWrapper::nextPreset() {
    const unsigned int n = impl_->pm->getPlaylistSize();
    if (n == 0) return;
    unsigned int idx = 0;
    const bool have = impl_->pm->selectedPresetIndex(idx);
    impl_->pm->selectPreset(have ? (idx + 1) % n : 0, true);
}

void ProjectMWrapper::prevPreset() {
    const unsigned int n = impl_->pm->getPlaylistSize();
    if (n == 0) return;
    unsigned int idx = 0;
    const bool have = impl_->pm->selectedPresetIndex(idx);
    impl_->pm->selectPreset(have ? (idx + n - 1) % n : 0, true);
}

void ProjectMWrapper::playPresetAt(int index) {
    if (index >= 0 && index < (int)impl_->pm->getPlaylistSize())
        impl_->pm->selectPreset((unsigned int)index, true);
}

std::vector<std::string> ProjectMWrapper::presetPaths() const {
    // v3 legacy backend: no bulk item API wired — search UI stays empty
    return {};
}

int ProjectMWrapper::lastSwitchedPreset() const {
    unsigned int idx = 0;
    return impl_->pm->selectedPresetIndex(idx) ? (int)idx : -1;
}

void ProjectMWrapper::feedPcm(const float* interleaved, std::size_t floatCount) {
    // v3: 'samples' = TOTAL interleaved floats (2x frames).
    impl_->pm->pcm()->addPCMfloat_2ch(interleaved, static_cast<int>(floatCount));
}

int ProjectMWrapper::playlistSize() const {
    return static_cast<int>(impl_->pm->getPlaylistSize());
}
// v3 API differs: preset duration is a no-op on the legacy backend (v4 is
// the built path).
void ProjectMWrapper::setBeatSensitivity(float s) { impl_->pm->setBeatSensitivity(s); }
void ProjectMWrapper::setPresetDuration(double) {}
void ProjectMWrapper::setShuffle(bool on) { impl_->pm->setShuffleEnabled(on); }
void ProjectMWrapper::setPresetLocked(bool locked) { impl_->pm->setPresetLock(locked); }

#endif
