#pragma once
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QPointer>
#include <QProcess>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QRandomGenerator>
#include <QRasterWindow>
#include <QScreen>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QVariantAnimation>
#include <cstdio>
#include <functional>
#include <memory>
#include <rhi/qrhi.h>
#include <thread>

// The startup splash: melo runs itself again as `melo --splash`, which shows
// one of the logo looks in <qml>/splash until melo's window shows. A process
// of its own, because melo's GUI thread is busy building the window until then.
//
// A plain window paints the look's still frame at once. The look renders live
// offscreen meanwhile and takes over once it has settled, since its first
// render compiles shaders (~1.6 s on a GPU). A software renderer keeps the still.

inline constexpr QSize kSplashSize(560, 200);

// a fill with a layer that moves
inline bool splashPartMoves(const QJsonValue& part) {
    const QJsonObject o = part.toObject();
    const QJsonArray layers = o.contains(QStringLiteral("layers")) ? o[QStringLiteral("layers")].toArray()
                                                                  : QJsonArray{o};
    for (const QJsonValue& l : layers)
        if (l.toObject()[QStringLiteral("params")].toObject()[QStringLiteral("speed")].toDouble() > 0)
            return true;
    return false;
}

inline QString splashSlug(const QString& name) {
    QString s;
    for (const QChar c : name.toLower()) s += c.isLetterOrNumber() ? c : QChar('-');
    return s;
}

class SplashWindow : public QRasterWindow {
public:
    SplashWindow() {
        setFlags(Qt::SplashScreen | Qt::FramelessWindowHint);
        setTitle(QStringLiteral("melo"));
        QSurfaceFormat f = format();
        f.setAlphaBufferSize(8);   // see-through around the logo
        setFormat(f);
        resize(kSplashSize);
        // placed only where the client may place itself (X11, Windows)
        if (QScreen* s = QGuiApplication::primaryScreen())
            setPosition(s->availableGeometry().center() - QPoint(width() / 2, height() / 2));
    }
    void setFrame(const QImage& frame) { frame_ = frame; update(); }
    bool fading() const { return fading_; }
    // runs once, after the first paint: the window knows its scale by then
    std::function<void()> afterFirstPaint;
    // painted, not QWindow::setOpacity: Wayland has no window opacity
    void fadeOut() {
        if (fading_) return;
        fading_ = true;
        auto* a = new QVariantAnimation(this);
        a->setDuration(150);
        a->setStartValue(1.0);
        a->setEndValue(0.0);
        QObject::connect(a, &QVariantAnimation::valueChanged, this, [this](const QVariant& v) {
            opacity_ = v.toReal();
            update();
        });
        QObject::connect(a, &QVariantAnimation::finished, qApp, &QCoreApplication::quit);
        a->start(QAbstractAnimation::DeleteWhenStopped);
    }

protected:
    void paintEvent(QPaintEvent*) override {
        QPainter p(this);
        p.setCompositionMode(QPainter::CompositionMode_Source);
        p.fillRect(QRect(QPoint(0, 0), size()), Qt::transparent);
        p.setCompositionMode(QPainter::CompositionMode_SourceOver);
        p.setRenderHint(QPainter::SmoothPixmapTransform);
        p.setOpacity(opacity_);
        p.drawImage(QRectF(QPointF(0, 0), QSizeF(size())), frame_);
        if (painted_) return;
        painted_ = true;
        std::fprintf(stderr, "[splash] first frame\n");
        if (afterFirstPaint) QTimer::singleShot(0, this, afterFirstPaint);
    }

private:
    QImage frame_;
    bool fading_ = false;
    bool painted_ = false;
    qreal opacity_ = 1.0;
};

// SplashScene.qml rendered offscreen into a texture and read back each frame.
class SplashRenderer : public QObject {
public:
    // dpr: output pixels per scene unit
    bool start(const QString& dir, const QJsonObject& look, qreal dpr) {
        window_ = std::make_unique<QQuickWindow>(&control_);
        window_->setColor(Qt::transparent);
        component_ = std::make_unique<QQmlComponent>(&engine_,
            QUrl::fromLocalFile(dir + QStringLiteral("/SplashScene.qml")));
        scene_ = qobject_cast<QQuickItem*>(component_->createWithInitialProperties(
            {{QStringLiteral("look"), look.toVariantMap()}}));
        if (!scene_) return false;
        scene_->setParentItem(window_->contentItem());
        window_->contentItem()->setSize(QSizeF(kSplashSize));
        window_->setGeometry(QRect(QPoint(0, 0), kSplashSize));
        if (!control_.initialize()) return false;
        QRhi* rhi = control_.rhi();
        // Refuse a software renderer, so the splash keeps its still: it would draw
        // the fills on the CPU that melo's own startup needs. OpenGL reports no
        // device type, only the renderer's name.
        const QRhiDriverInfo info = rhi->driverInfo();
        static const char* const cpu[] = {"llvmpipe", "softpipe", "swiftshader", "software rasterizer",
                                          "basic render"};
        if (info.deviceType == QRhiDriverInfo::CpuDevice) return false;
        for (const char* name : cpu)
            if (info.deviceName.toLower().contains(name)) return false;
        const QSize px = (QSizeF(kSplashSize) * dpr).toSize();
        tex_.reset(rhi->newTexture(QRhiTexture::RGBA8, px, 1,
                                   QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource));
        ds_.reset(rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, px, 1));
        if (!tex_->create() || !ds_->create()) return false;
        QRhiTextureRenderTargetDescription desc{QRhiColorAttachment(tex_.get())};
        desc.setDepthStencilBuffer(ds_.get());
        rt_.reset(rhi->newTextureRenderTarget(desc));
        rp_.reset(rt_->newCompatibleRenderPassDescriptor());
        rt_->setRenderPassDescriptor(rp_.get());
        if (!rt_->create()) return false;
        QQuickRenderTarget target = QQuickRenderTarget::fromRhiRenderTarget(rt_.get());
        target.setDevicePixelRatio(dpr);
        window_->setRenderTarget(target);
        return true;
    }
    void setHold(bool hold) { scene_->setProperty("hold", hold); }
    QImage render() {
        control_.polishItems();
        control_.beginFrame();
        control_.sync();
        control_.render();
        QRhiReadbackResult result;
        QRhiResourceUpdateBatch* batch = control_.rhi()->nextResourceUpdateBatch();
        batch->readBackTexture(tex_.get(), &result);
        control_.commandBuffer()->resourceUpdate(batch);
        control_.endFrame();   // an offscreen frame: the readback is done here
        const QImage img(reinterpret_cast<const uchar*>(result.data.constData()),
                         result.pixelSize.width(), result.pixelSize.height(),
                         QImage::Format_RGBA8888_Premultiplied);
        return control_.rhi()->isYUpInFramebuffer() ? img.flipped() : img.copy();
    }

private:
    QQmlEngine engine_;
    QQuickRenderControl control_;
    std::unique_ptr<QQuickWindow> window_;
    std::unique_ptr<QQmlComponent> component_;
    QQuickItem* scene_ = nullptr;
    std::unique_ptr<QRhiTexture> tex_;
    std::unique_ptr<QRhiRenderBuffer> ds_;
    std::unique_ptr<QRhiTextureRenderTarget> rt_;
    std::unique_ptr<QRhiRenderPassDescriptor> rp_;
};

// Renders with the clock held until two frames match: the distance fields
// have settled and the picture is the still frame's.
inline QImage settleSplash(SplashRenderer& r, const std::function<bool()>& stop = {}) {
    QImage prev;
    for (int i = 0; i < 30 && !(stop && stop()); ++i) {
        QImage img = r.render();
        if (img == prev) return img;
        prev = img;
        QCoreApplication::processEvents();
    }
    return prev;
}

// `melo --splash [--look=<name>] [--still=<file>]`: up until a byte arrives on
// stdin or stdin closes (melo showed its window, or melo is gone), then fades
// out. --still writes the look's still frame instead.
inline int runSplash(int argc, char** argv, QString (*qmlDir)()) {
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("melo"));   // melo's cache folders
    QString wantLook, stillOut;
    for (const QString& a : QCoreApplication::arguments()) {
        if (a.startsWith(QStringLiteral("--look="))) wantLook = a.mid(7);
        if (a.startsWith(QStringLiteral("--still="))) stillOut = a.mid(8);
    }

    const QString dir = qmlDir() + QStringLiteral("/splash");
    QFile f(dir + QStringLiteral("/looks.json"));
    if (!f.open(QIODevice::ReadOnly)) return 0;
    QJsonArray pool;
    for (const QJsonValue& v : QJsonDocument::fromJson(f.readAll()).array())
        if (wantLook.isEmpty() || v.toObject()[QStringLiteral("name")].toString() == wantLook)
            pool.append(v);
    if (pool.isEmpty()) return 0;
    const QJsonObject look = pool.at(QRandomGenerator::global()->bounded(int(pool.size()))).toObject();
    const QString slug = splashSlug(look[QStringLiteral("name")].toString());
    bool moves = false;
    for (const QJsonValue& p : look[QStringLiteral("parts")].toObject())
        moves = moves || splashPartMoves(p);

    if (!stillOut.isEmpty()) {
        SplashRenderer r;
        if (!r.start(dir, look, 2.0)) return 1;
        return settleSplash(r).save(stillOut) ? 0 : 1;
    }

    SplashWindow w;
    w.setFrame(QImage(dir + QStringLiteral("/stills/") + slug + QStringLiteral(".webp")));
    w.show();
    std::thread([&w] {
        char c;
        (void)std::fread(&c, 1, 1, stdin);
        QMetaObject::invokeMethod(&w, [&w] { w.fadeOut(); }, Qt::QueuedConnection);
    }).detach();
    // a melo that hangs before its window must not leave this up for good
    QTimer::singleShot(30000, &app, &QCoreApplication::quit);

    // live once the still is on screen
    SplashRenderer live;
    QTimer tick;
    // a look that does not move is its still: nothing to render
    // melo can show before the live look is ready (its shaders compile
    // slowly on a new GPU driver); from then on the look is not wanted
    if (moves) w.afterFirstPaint = [&] {
        if (!live.start(dir, look, w.devicePixelRatio())) {
            std::fprintf(stderr, "[splash] still only\n");
            return;
        }
        QCoreApplication::processEvents();
        const QImage settled = settleSplash(live, [&w] { return w.fading(); });
        if (w.fading()) return;
        w.setFrame(settled);
        live.setHold(false);
        std::fprintf(stderr, "[splash] live, look %s\n", qPrintable(look[QStringLiteral("name")].toString()));
        QObject::connect(&tick, &QTimer::timeout, &app, [&] { w.setFrame(live.render()); });
        tick.start(16);
    };
    return app.exec();
}

// melo's side: starts the splash and tells it when the window is up.
class SplashLauncher {
public:
    void start() {
        proc_.setProgram(QCoreApplication::applicationFilePath());
        proc_.setArguments({QStringLiteral("--splash")});
        // the launcher's activation token is for melo's window: a splash that
        // opened with it would spend it, and the window would open unfocused
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.remove(QStringLiteral("XDG_ACTIVATION_TOKEN"));
        env.remove(QStringLiteral("DESKTOP_STARTUP_ID"));
        proc_.setProcessEnvironment(env);
        proc_.setStandardOutputFile(QProcess::nullDevice());
        // MELO_SPLASH_LOG=1 lets its log through
        if (qEnvironmentVariableIsSet("MELO_SPLASH_LOG")) proc_.setProcessChannelMode(QProcess::ForwardedErrorChannel);
        else proc_.setStandardErrorFile(QProcess::nullDevice());
        proc_.start();
    }
    void close() {
        if (proc_.state() == QProcess::NotRunning) return;
        proc_.write("x", 1);
        proc_.closeWriteChannel();
    }
    ~SplashLauncher() {
        close();
        // the fade is 150 ms; melo quitting before then takes the splash with it
        if (!proc_.waitForFinished(500)) proc_.kill();
    }

private:
    QProcess proc_;
};
