#include "VisualizerItem.h"
#include "ProjectMWrapper.h"
#include "PcmQueue.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QDir>
#include <QFileInfo>
#include <QOffscreenSurface>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QOpenGLExtraFunctions>
#include <QOpenGLContext>
#include <QQuickOpenGLUtils>
#include <QQuickWindow>
#include <cstdio>
#include <cmath>
#include <cstdlib>

PcmQueue* VisualizerItem::s_pcm = nullptr;
int VisualizerItem::s_engines = 0;

// projectM and its picture. The shared one has a GL context of its own, sharing
// with every window's, so the visualizer keeps its picture as it moves between
// melo, the mini popup and its own window; a projectM in a window's context starts
// again from black in each.
struct VisEngine {
    std::unique_ptr<QOffscreenSurface> surface;   // the GUI thread's to create
    std::unique_ptr<QOpenGLContext> ctx;          // none: the window's own context
    std::unique_ptr<ProjectMWrapper> pm;
    std::unique_ptr<QOpenGLFramebufferObject> fbo;
    bool unshared = false;

    explicit VisEngine(bool own) {
        if (!own) return;
        surface = std::make_unique<QOffscreenSurface>();
        surface->setFormat(QSurfaceFormat::defaultFormat());
        surface->create();
    }
    ~VisEngine() {
        if (!ctx) return;
        QOpenGLContext* was = QOpenGLContext::currentContext();
        QSurface* wasOn = was ? was->surface() : nullptr;
        if (ctx->makeCurrent(surface.get())) {
            pm.reset();
            fbo.reset();
            ctx->doneCurrent();
        }
        if (was && wasOn) was->makeCurrent(wasOn);
    }
    // this engine's context current; false, with the window's still current, when it
    // has none that shares with the window's
    bool enter(QOpenGLContext* win) {
        if (unshared || !surface) return false;
        if (!ctx) {
            ctx = std::make_unique<QOpenGLContext>();
            ctx->setFormat(QSurfaceFormat::defaultFormat());
            ctx->setShareContext(QOpenGLContext::globalShareContext());
            if (!surface->isValid() || !ctx->create() || !QOpenGLContext::areSharing(ctx.get(), win)) {
                std::fprintf(stderr, "[vis] no GL context shared with the windows': the picture restarts in each window\n");
                unshared = true;
                ctx.reset();
                return false;
            }
        }
        if (ctx->makeCurrent(surface.get())) return true;
        win->makeCurrent(win->surface());
        return false;
    }
};

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

// Draws the engine's picture into the item's FBO, in whichever window holds the item.
class PMRenderer : public QQuickFramebufferObject::Renderer {
public:
    explicit PMRenderer(const VisualizerItem* item) : item_(item), shared_(item->engine_) {}

    QOpenGLFramebufferObject* createFramebufferObject(const QSize& size) override {
        // Window transitions can momentarily hand us zero/negative sizes;
        // a degenerate FBO (and projectM resize) crashes. Clamp to 1x1.
        fbSize_ = QSize(qMax(1, size.width()), qMax(1, size.height()));
        return new QOpenGLFramebufferObject(fbSize_);
    }

    void render() override {
        QOpenGLContext* win = QOpenGLContext::currentContext();
        QSurface* winSurface = win->surface();
        const bool own = shared_->enter(win);
        if (!own && !local_) local_ = std::make_unique<VisEngine>(false);
        VisEngine& e = own ? *shared_ : *local_;
        auto* f = QOpenGLContext::currentContext()->functions();
        if (!e.pm) {
            e.pm = std::make_unique<ProjectMWrapper>(
                fbSize_.width(), fbSize_.height(), resolvePresetDir(), kDataDir);
            ++VisualizerItem::s_engines;
            std::fprintf(stderr, "[vis] projectM ready, playlist=%d\n", e.pm->playlistSize());
            // one built for another window takes the preset and the settings on screen
            const int at = item_->currentIndex_.load();
            if (at >= 0 && item_->presetIdxRequested_.load() < 0) item_->presetIdxRequested_.store(at);
            item_->settingsDirty_.store(true);
        }
        if (!e.fbo || e.fbo->size() != fbSize_) {
            QOpenGLFramebufferObjectFormat fmt;
            fmt.setAttachment(QOpenGLFramebufferObject::CombinedDepthStencil);
            e.fbo = std::make_unique<QOpenGLFramebufferObject>(fbSize_, fmt);
            e.pm->resize(fbSize_.width(), fbSize_.height());
        }
        ProjectMWrapper* pm = e.pm.get();
        if (item_->settingsDirty_.exchange(false)) {
            pm->setBeatSensitivity((float)item_->beatSensitivity_.load());
            pm->setPresetDuration(item_->presetDuration_.load());
            pm->setShuffle(item_->shuffle_.load());
            pm->setPresetLocked(item_->presetLocked_.load());
        }
        if (item_->nextPresetRequested_.exchange(false)) pm->nextPreset();
        if (item_->prevPresetRequested_.exchange(false)) pm->prevPreset();
        const int reqIdx = item_->presetIdxRequested_.exchange(-1);
        if (reqIdx >= 0) pm->playPresetAt(reqIdx);
        if (!item_->presetNamesSent_.exchange(true)) {
            // playlist is render-thread-owned; push display names to the item
            // once for the config panel's preset search
            QStringList names;
            for (const auto& p : pm->presetPaths())
                names << QFileInfo(QString::fromStdString(p)).completeBaseName();
            QMetaObject::invokeMethod(const_cast<VisualizerItem*>(item_), "setPresetNames",
                                      Qt::QueuedConnection, Q_ARG(QStringList, names));
        }
        if (VisualizerItem::s_pcm)
            VisualizerItem::s_pcm->drain([this, pm](const float* d, std::size_t n) {
                pm->feedPcm(d, n);
                if (trace_) {
                    fed_ += n;
                    for (std::size_t i = 0; i < n; ++i) peak_ = std::max(peak_, std::fabs(d[i]));
                }
            });

        const int switched = pm->lastSwitchedPreset();
        if (switched != lastPresetSeen_) {
            lastPresetSeen_ = switched;
            QMetaObject::invokeMethod(const_cast<VisualizerItem*>(item_), "setCurrentPresetIndex",
                                      Qt::QueuedConnection, Q_ARG(int, switched));
        }

        // Rebind the engine's framebuffer: projectM's setup and preset loads leave
        // framebuffer 0 bound, and a frame drawn there never reaches the picture.
        e.fbo->bind();
        f->glDisable(GL_BLEND);
        f->glDisable(GL_SCISSOR_TEST);
        f->glClearColor(0.f, 0.f, 0.f, 1.f);
        f->glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        pm->renderFrame();   // patched projectM: outputs to the caller-bound FBO

        // back to the window's context, which reads the picture once it is drawn
        GLsync drawn = nullptr;
        if (own) {
            drawn = QOpenGLContext::currentContext()->extraFunctions()->glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            f->glFlush();
            win->makeCurrent(winSurface);
        }
        auto* x = win->extraFunctions();
        if (drawn) {
            x->glWaitSync(drawn, 0, GL_TIMEOUT_IGNORED);
            x->glDeleteSync(drawn);
        }
        // framebuffers are not shared between contexts: this one is the window's
        if (!readFbo_) { x->glGenFramebuffers(1, &readFbo_); readCtx_ = win; }
        x->glBindFramebuffer(GL_READ_FRAMEBUFFER, readFbo_);
        x->glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, e.fbo->texture(), 0);
        x->glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebufferObject()->handle());
        x->glDisable(GL_SCISSOR_TEST);
        x->glBlitFramebuffer(0, 0, fbSize_.width(), fbSize_.height(), 0, 0, fbSize_.width(), fbSize_.height(),
                             GL_COLOR_BUFFER_BIT, GL_NEAREST);
        x->glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        framebufferObject()->bind();

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
    ~PMRenderer() override {
        if (readFbo_ && QOpenGLContext::currentContext() == readCtx_)
            readCtx_->extraFunctions()->glDeleteFramebuffers(1, &readFbo_);
        if (trace_) std::fprintf(stderr, "[vispcm] %p gone\n", static_cast<const void*>(this));
    }

private:
    const VisualizerItem* item_;
    std::shared_ptr<VisEngine> shared_;
    std::unique_ptr<VisEngine> local_;   // this window's own, when nothing shares
    GLuint readFbo_ = 0;
    QOpenGLContext* readCtx_ = nullptr;
    QSize fbSize_;
    int lastPresetSeen_ = -1;
    const bool trace_ = qEnvironmentVariableIsSet("MELO_GEOM_DEBUG");
    int frames_ = 0;
    std::size_t fed_ = 0;
    float peak_ = 0;
    QElapsedTimer statClock_;
};
} // namespace

VisualizerItem::VisualizerItem() : engine_(std::make_shared<VisEngine>(true)) {
    setMirrorVertically(true);   // GL FBO vs QML y-axis
}

VisualizerItem::~VisualizerItem() = default;

void VisualizerItem::itemChange(ItemChange change, const ItemChangeData& value) {
    if (change == ItemVisibleHasChanged) {   // EFFECTIVE visibility
        pumpOn_.store(value.boolValue);
        if (value.boolValue) update();       // restart the render loop
    }
    QQuickFramebufferObject::itemChange(change, value);
}

QQuickFramebufferObject::Renderer* VisualizerItem::createRenderer() const {
    return new PMRenderer(this);
}
