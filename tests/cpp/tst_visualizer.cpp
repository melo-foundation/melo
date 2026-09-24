// Asserts the visualiser's pixels: a working GL context, loaded presets and a
// drawing scene graph can still produce a black picture with nothing logged.
// Runs the app's classes (VisualizerItem, PMRenderer, PcmQueue) and grabs one
// frame through QQuickWindow::grabWindow(). Skipped, not failed, without a GL
// 3.3 context, so a red row never means "no GPU".
#include <QtTest>
#include <QDir>
#include <QDirIterator>
#include <QGuiApplication>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QQuickItem>
#include <QQuickWindow>
#include <cmath>
#include <vector>

#include "PcmQueue.h"
#include "VisualizerItem.h"

class TstVisualizer : public QObject {
    Q_OBJECT

    // A second of 440Hz, which is what projectM reacts to. Silence is a
    // legitimate reason for a dark frame, so the test never asks that question.
    static std::vector<float> tone(int frames = 4096) {
        std::vector<float> pcm(std::size_t(frames) * 2);
        for (int i = 0; i < frames; ++i) {
            const float s = 0.8f * std::sin(2.0f * float(M_PI) * 440.0f * float(i) / 44100.0f);
            pcm[std::size_t(i) * 2] = s;
            pcm[std::size_t(i) * 2 + 1] = s;
        }
        return pcm;
    }

    // The same format melo asks for, in the same order. A skip that says
    // "no GL here" on a machine that has it is worse than no test, so this
    // reports which step failed and what it got.
    static bool haveGl(QString* why) {
        QSurfaceFormat fmt;
        fmt.setRenderableType(QSurfaceFormat::OpenGL);
        fmt.setVersion(3, 3);
        fmt.setProfile(QSurfaceFormat::CompatibilityProfile);
        fmt.setAlphaBufferSize(8);
        QSurfaceFormat::setDefaultFormat(fmt);

        QOpenGLContext ctx;
        ctx.setFormat(fmt);
        if (!ctx.create()) { *why = QStringLiteral("QOpenGLContext::create() failed"); return false; }
        QOffscreenSurface surf;
        surf.setFormat(ctx.format());
        surf.create();
        if (!surf.isValid()) { *why = QStringLiteral("QOffscreenSurface is not valid"); return false; }
        if (!ctx.makeCurrent(&surf)) {
            *why = QStringLiteral("makeCurrent failed on an offscreen surface (got %1.%2)")
                       .arg(ctx.format().majorVersion()).arg(ctx.format().minorVersion());
            return false;
        }
        const QSurfaceFormat got = ctx.format();
        ctx.doneCurrent();
        if (got.majorVersion() > 3 || (got.majorVersion() == 3 && got.minorVersion() >= 3))
            return true;
        *why = QStringLiteral("OpenGL %1.%2 is below 3.3").arg(got.majorVersion()).arg(got.minorVersion());
        return false;
    }

private slots:
    void initTestCase() {
        // The item is a QQuickFramebufferObject writing into the scene graph's
        // own FBO — it only works on the OpenGL RHI backend, which is what
        // main.cpp forces for the same reason.
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    }

    void rendersMoreThanBlack() {
        QString why;
        if (!haveGl(&why))
            QSKIP(qPrintable(QStringLiteral("no usable OpenGL 3.3: ") + why));

        PcmQueue pcm;
        VisualizerItem::setPcmQueue(&pcm);
        const std::vector<float> t = tone();

        QQuickWindow win;
        win.resize(320, 240);
        // A clear colour that is not black: all black means the grab never
        // ran a render pass, while all this colour means the window rendered
        // and the visualiser drew nothing into it.
        const QColor clear(32, 0, 48);
        win.setColor(clear);
        auto* viz = new VisualizerItem;
        viz->setParentItem(win.contentItem());
        viz->setSize(QSizeF(320, 240));
        // Shown, because a QQuickFramebufferObject renders during a
        // real render pass; an unexposed window can be grabbed and come back
        // black for reasons that have nothing to do with projectM. On the
        // offscreen platform "shown" costs nothing visible.
        win.show();
        // A compositor that will not map a window — a locked session, a
        // headless login — never exposes it, and everything below would then
        // fail for a reason that has nothing to do with the visualiser.
        if (!QTest::qWaitForWindowExposed(&win))
            QSKIP("the window system would not expose a window (locked session?), so the frame "
                  "could not be measured — run this on a live desktop or under xvfb");

        // projectM needs a few frames: the first builds the context and
        // compiles the preset, and a preset that fails compiling falls back to
        // the next one. Ten is generous and still under a second.
        QImage shot;
        for (int i = 0; i < 10; ++i) {
            pcm.push(t.data(), t.size());
            viz->update();
            shot = win.grabWindow();
            QTest::qWait(30);
            if (!shot.isNull() && !isUniform(shot)) break;
        }

        QVERIFY2(!shot.isNull(), "grabWindow returned nothing — the window never rendered");

        // With an empty playlist projectM's idle preset animates and passes the
        // render check, so check that presets loaded. Names arrive queued a
        // frame or two late.
        QTRY_VERIFY_WITH_TIMEOUT(!viz->presetNames().isEmpty() || !presetsOnDisk(), 3000);
        if (!presetsOnDisk())
            QSKIP("no preset pack on this machine (run scripts/fetch-presets.sh); "
                  "the render assertion below would pass on projectM's idle preset alone");
        QVERIFY2(!viz->presetNames().isEmpty(),
                 qPrintable(QStringLiteral(
                     "presets exist on disk but projectM loaded NONE — a packaged build in "
                     "this state renders its idle preset and looks like it is working. Dir: %1")
                     .arg(presetDir())));

        // What the driver actually gave us, named in the failure rather than
        // left to be guessed at from another machine.
        QString gl;
        {
            QOpenGLContext ctx;
            ctx.create();
            QOffscreenSurface surf;
            surf.setFormat(ctx.format());
            surf.create();
            if (ctx.makeCurrent(&surf)) {
                auto* f = ctx.functions();
                gl = QStringLiteral("%1 / %2")
                         .arg(QString::fromLatin1(
                                  reinterpret_cast<const char*>(f->glGetString(GL_RENDERER))),
                              QString::fromLatin1(
                                  reinterpret_cast<const char*>(f->glGetString(GL_VERSION))));
                ctx.doneCurrent();
            }
        }
        // A uniform frame fails whatever its colour: projectM's FBO can reach
        // the window carrying flat black, which differs from the clear colour.
        // A visualiser frame is never one colour; the clear colour only tells
        // us why a frame is uniform.
        const bool sawClear = countOf(shot, clear) > 0;

        // Under a software rasteriser the preset draws one flat colour while
        // the plumbing works; a frame that is the clear colour still fails
        // everywhere.
        const bool softwareGl = gl.contains(QLatin1String("llvmpipe"), Qt::CaseInsensitive)
                             || gl.contains(QLatin1String("softpipe"), Qt::CaseInsensitive)
                             || gl.contains(QLatin1String("swrast"), Qt::CaseInsensitive);
        if (softwareGl && isUniform(shot) && !sawClear) {
            QSKIP(qPrintable(QStringLiteral(
                "software rasteriser (%1): the item's FBO reached the window — which is what "
                "this suite guards — but projectM's preset rendered one flat colour on it. "
                "Whether a preset DRAWS needs a real GPU; run this on one before trusting the "
                "visualiser.").arg(gl)));
        }

        QVERIFY2(!isUniform(shot),
                 qPrintable(QStringLiteral(
                     "%1x%2 of ONE FLAT COLOUR. %3 GL: %4. Presets: %5")
                     .arg(shot.width()).arg(shot.height())
                     .arg(sawClear
                              ? QStringLiteral("It is the window's own clear colour, so the "
                                               "item drew nothing into the frame at all.")
                              : QStringLiteral("It is NOT the clear colour, so the item's FBO "
                                               "did reach the window carrying one flat colour "
                                               "— projectM ran and produced nothing."),
                          gl.isEmpty() ? QStringLiteral("(unknown)") : gl,
                          qEnvironmentVariable("MELO_PRESETDIR", QStringLiteral("(default)")))));
    }

private:
    // The same resolution order VisualizerItem uses, so the test measures the
    // directory the app would actually load from.
    static QString presetDir() {
        if (qEnvironmentVariableIsSet("MELO_PRESETDIR")) return qEnvironmentVariable("MELO_PRESETDIR");
        const QString local = QCoreApplication::applicationDirPath() + "/presets";
        if (QDir(local).exists()) return local;
#ifdef MELO_DEV_PRESET_DIR
        if (QDir(QStringLiteral(MELO_DEV_PRESET_DIR)).exists()) return MELO_DEV_PRESET_DIR;
#endif
        return QStringLiteral("/usr/share/melo/presets");
    }
    static bool presetsOnDisk() {
        QDirIterator it(presetDir(), {"*.milk"}, QDir::Files, QDirIterator::Subdirectories);
        return it.hasNext();
    }

    // Any pixel meaningfully different from the window's clear colour. Not an
    // average: a preset that lights one corner is still a preset that renders.
    static bool anythingBut(const QImage& img, const QColor& clear) {
        const int cr = clear.red(), cg = clear.green(), cb = clear.blue();
        for (int y = 0; y < img.height(); ++y)
            for (int x = 0; x < img.width(); ++x) {
                const QRgb p = img.pixel(x, y);
                if (qAbs(qRed(p) - cr) > 12 || qAbs(qGreen(p) - cg) > 12
                    || qAbs(qBlue(p) - cb) > 12)
                    return true;
            }
        return false;
    }

    // Every pixel the same, within tolerance. The one property a working
    // visualiser frame never has.
    static bool isUniform(const QImage& img) {
        if (img.isNull()) return true;
        const QRgb first = img.pixel(0, 0);
        for (int y = 0; y < img.height(); ++y)
            for (int x = 0; x < img.width(); ++x) {
                const QRgb p = img.pixel(x, y);
                if (qAbs(qRed(p) - qRed(first)) > 12 || qAbs(qGreen(p) - qGreen(first)) > 12
                    || qAbs(qBlue(p) - qBlue(first)) > 12)
                    return false;
            }
        return true;
    }

    static int countOf(const QImage& img, const QColor& c) {
        int n = 0;
        for (int y = 0; y < img.height(); ++y)
            for (int x = 0; x < img.width(); ++x) {
                const QRgb p = img.pixel(x, y);
                if (qAbs(qRed(p) - c.red()) <= 8 && qAbs(qGreen(p) - c.green()) <= 8
                    && qAbs(qBlue(p) - c.blue()) <= 8)
                    ++n;
            }
        return n;
    }
};

QTEST_MAIN(TstVisualizer)
#include "tst_visualizer.moc"
