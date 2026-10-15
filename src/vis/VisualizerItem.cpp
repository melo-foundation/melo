#include "VisualizerItem.h"
#include "ProjectMWrapper.h"
#include "PcmQueue.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QDir>
#include <QFileInfo>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QOpenGLContext>
#include <QQuickOpenGLUtils>
#include <QQuickWindow>
#include <cstdio>
#include <cmath>
#include <cstdlib>

PcmQueue* VisualizerItem::s_pcm = nullptr;

namespace {
// Preset dir: env override -> beside the executable (packaged Windows/portable
// layout) -> dev vendor dir (compiled in) -> installed share dir.
std::string resolvePresetDir() {
    if (const char* env = std::getenv("MELO_PRESETDIR")) return env;
    const QString local = QCoreApplication::applicationDirPath() + "/presets";
    if (QDir(local).exists()) return local.toStdString();
#ifdef MELO_DEV_PRESET_DIR
    if (QDir(QStringLiteral(MELO_DEV_PRESET_DIR)).exists()) return MELO_DEV_PRESET_DIR;
#endif
    return "/usr/share/melo/presets";
}
constexpr const char* kDataDir = "/usr/share/projectM";

class PMRenderer : public QQuickFramebufferObject::Renderer {
public:
    explicit PMRenderer(const VisualizerItem* item) : item_(item) {}

    QOpenGLFramebufferObject* createFramebufferObject(const QSize& size) override {
        // Window transitions can momentarily hand us zero/negative sizes;
        // a degenerate FBO (and projectM resize) crashes. Clamp to 1x1.
        fbSize_ = QSize(qMax(1, size.width()), qMax(1, size.height()));
        if (pm_) pm_->resize(fbSize_.width(), fbSize_.height());
        QOpenGLFramebufferObjectFormat fmt;
        fmt.setAttachment(QOpenGLFramebufferObject::CombinedDepthStencil);
        return new QOpenGLFramebufferObject(fbSize_, fmt);
    }

    void render() override {
        auto* f = QOpenGLContext::currentContext()->functions();
        if (!pm_) {
            pm_ = std::make_unique<ProjectMWrapper>(
                fbSize_.width(), fbSize_.height(), resolvePresetDir(), kDataDir);
            std::fprintf(stderr, "[vis] projectM ready, playlist=%d\n", pm_->playlistSize());
        }
        if (item_->settingsDirty_.exchange(false)) {
            pm_->setBeatSensitivity((float)item_->beatSensitivity_.load());
            pm_->setPresetDuration(item_->presetDuration_.load());
            pm_->setShuffle(item_->shuffle_.load());
            pm_->setPresetLocked(item_->presetLocked_.load());
        }
        if (item_->nextPresetRequested_.exchange(false)) pm_->nextPreset();
        if (item_->prevPresetRequested_.exchange(false)) pm_->prevPreset();
        const int reqIdx = item_->presetIdxRequested_.exchange(-1);
        if (reqIdx >= 0) pm_->playPresetAt(reqIdx);
        if (!item_->presetNamesSent_.exchange(true)) {
            // playlist is render-thread-owned; push display names to the item
            // once for the config panel's preset search
            QStringList names;
            for (const auto& p : pm_->presetPaths())
                names << QFileInfo(QString::fromStdString(p)).completeBaseName();
            QMetaObject::invokeMethod(const_cast<VisualizerItem*>(item_), "setPresetNames",
                                      Qt::QueuedConnection, Q_ARG(QStringList, names));
        }
        if (VisualizerItem::s_pcm)
            VisualizerItem::s_pcm->drain([this](const float* d, std::size_t n) {
                pm_->feedPcm(d, n);
                if (trace_) {
                    fed_ += n;
                    for (std::size_t i = 0; i < n; ++i) peak_ = std::max(peak_, std::fabs(d[i]));
                }
            });

        const int switched = pm_->lastSwitchedPreset();
        if (switched != lastPresetSeen_) {
            lastPresetSeen_ = switched;
            QMetaObject::invokeMethod(const_cast<VisualizerItem*>(item_), "setCurrentPresetIndex",
                                      Qt::QueuedConnection, Q_ARG(int, switched));
        }

        // Rebind the item's framebuffer: projectM's setup and preset loads leave
        // framebuffer 0 bound, and a frame drawn there never reaches the item's texture.
        framebufferObject()->bind();
        f->glDisable(GL_BLEND);
        f->glDisable(GL_SCISSOR_TEST);
        f->glClearColor(0.f, 0.f, 0.f, 1.f);
        f->glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        pm_->renderFrame();   // patched projectM: outputs to the caller-bound FBO

        // projectM trashes GL state; restore it for the Quick scenegraph.
        QQuickOpenGLUtils::resetOpenGLState();
        // continuous animation — but only while the item is on screen AND
        // something is playing (see pumpOn_/playing_ in the header;
        // itemChange() rekicks on re-show, setPlaying() on resume)
        if (item_->pumpOn_.load() && item_->playing_.load()) update();
        // MELO_GEOM_DEBUG: what reached this projectM each 2 s; peak 0 is silence
        if (trace_) {
            ++frames_;
            if (!statClock_.isValid()) statClock_.start();
            if (statClock_.elapsed() >= 2000) {
                std::fprintf(stderr, "[vispcm] %p frames %d fed %zu peak %.3f\n",
                             static_cast<const void*>(this), frames_, fed_, double(peak_));
                frames_ = 0; fed_ = 0; peak_ = 0; statClock_.restart();
            }
        }
    }
    ~PMRenderer() override { if (trace_) std::fprintf(stderr, "[vispcm] %p gone\n", static_cast<const void*>(this)); }

private:
    const VisualizerItem* item_;
    std::unique_ptr<ProjectMWrapper> pm_;
    QSize fbSize_;
    int lastPresetSeen_ = -1;
    const bool trace_ = qEnvironmentVariableIsSet("MELO_GEOM_DEBUG");
    int frames_ = 0;
    std::size_t fed_ = 0;
    float peak_ = 0;
    QElapsedTimer statClock_;
};
} // namespace

VisualizerItem::VisualizerItem() {
    setMirrorVertically(true);   // GL FBO vs QML y-axis
}

void VisualizerItem::itemChange(ItemChange change, const ItemChangeData& value) {
    // Another window is another renderer and a new projectM: it takes the preset
    // and the settings this one had.
    if (change == ItemSceneChange && value.window && currentIndex_ >= 0) {
        presetIdxRequested_.store(currentIndex_);
        settingsDirty_.store(true);
    }
    if (change == ItemVisibleHasChanged) {   // EFFECTIVE visibility
        pumpOn_.store(value.boolValue);
        if (value.boolValue) update();       // restart the render loop
    }
    QQuickFramebufferObject::itemChange(change, value);
}

QQuickFramebufferObject::Renderer* VisualizerItem::createRenderer() const {
    return new PMRenderer(this);
}
