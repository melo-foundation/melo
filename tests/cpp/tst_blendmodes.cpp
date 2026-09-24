#include <QtTest>
#include <QColor>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QQuickWindow>
#include <cmath>
#include <QSGRendererInterface>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QSurfaceFormat>

#include "BlendItem.h"

// BlendRect blends with the real framebuffer, which only a real window and a
// pixel grab can check (as tst_visualizer does). The background (64, 32, 96) is
// asymmetric so an ignored or swapped destination fails.
class TestBlendModes : public QObject {
    Q_OBJECT

    static constexpr int kW = 64, kH = 64;
    static const QColor& bg() { static const QColor c(64, 32, 96); return c; }

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
        if (!surf.isValid()) { *why = QStringLiteral("QOffscreenSurface invalid"); return false; }
        if (!ctx.makeCurrent(&surf)) { *why = QStringLiteral("makeCurrent failed"); return false; }
        ctx.doneCurrent();
        return true;
    }

    // Draw one BlendRect of `mode`/`colour` over bg() and return the middle pixel.
    QColor render(const QString& mode, const QColor& colour) {
        QQuickWindow win;
        win.resize(kW, kH);
        win.setColor(bg());
        auto* b = new BlendItem;
        b->setParentItem(win.contentItem());
        b->setSize(QSizeF(kW, kH));
        b->setColor(colour);
        b->setMode(mode);
        win.show();
        // A compositor that never maps the window (locked or headless session)
        // is not a blend failure; it is reported apart from a frame that
        // exposes and is wrong.
        if (!QTest::qWaitForWindowExposed(&win)) { exposed_ = false; return QColor(); }
        QImage shot;
        for (int i = 0; i < 5 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
        if (shot.isNull()) return QColor();
        return shot.pixelColor(kW / 2, kH / 2);
    }

    bool exposed_ = true;

    void near(const QColor& got, int r, int g, int bl, const char* what) {
        if (!exposed_)
            QSKIP("the window system would not expose a window (locked session?), so nothing "
                  "could be measured — run this on a live desktop or under xvfb");
        QVERIFY2(got.isValid(), qPrintable(QStringLiteral("%1: nothing rendered").arg(what)));
        // +-2 for the rounding a rasteriser is entitled to
        const QString msg = QStringLiteral("%1: wanted rgb(%2,%3,%4), got rgb(%5,%6,%7)")
            .arg(what).arg(r).arg(g).arg(bl).arg(got.red()).arg(got.green()).arg(got.blue());
        QVERIFY2(qAbs(got.red() - r) <= 2 && qAbs(got.green() - g) <= 2
                 && qAbs(got.blue() - bl) <= 2, qPrintable(msg));
    }

    // Build the scene from QML so the texture path uses the same
    // ShaderEffectSource shape melo does, and read the middle pixel.
    QColor renderQml(const QString& body) {
        QQmlEngine engine;
        QQmlComponent comp(&engine);
        comp.setData(QStringLiteral("import QtQuick\nimport Melo 1.0\n"
                                    "Item { width: %1; height: %2\n%3\n}")
                     .arg(kW).arg(kH).arg(body).toUtf8(), QUrl());
        if (comp.isError()) { qWarning("%s", qPrintable(comp.errorString())); return QColor(); }
        auto* root = qobject_cast<QQuickItem*>(comp.create());
        if (!root) return QColor();
        QQuickWindow win;
        win.resize(kW, kH);
        win.setColor(bg());
        root->setParentItem(win.contentItem());
        win.show();
        if (!QTest::qWaitForWindowExposed(&win)) { exposed_ = false; delete root; return QColor(); }
        QImage shot;
        for (int i = 0; i < 6 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
        const QColor c = shot.isNull() ? QColor() : shot.pixelColor(kW / 2, kH / 2);
        delete root;
        return c;
    }

private slots:
    void initTestCase() {
        QString why;
        if (!haveGl(&why)) QSKIP(qPrintable("no usable GL here: " + why));
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
        // The QML cases say `import Melo 1.0`, and this binary is not melo.
        qmlRegisterType<BlendItem>("Melo", 1, 0, "BlendRect");
    }

    // The headline: white through OneMinusDstColor/Zero is 1 - dst.
    void invertReturnsTheComplementOfWhatIsBehind() {
        near(render(QStringLiteral("invert"), Qt::white),
             255 - 64, 255 - 32, 255 - 96, "invert");
    }

    // ...and it is genuinely reading the destination, not producing a constant.
    void invertDependsOnTheBackdrop() {
        const QColor got = render(QStringLiteral("invert"), Qt::white);
        if (!exposed_) QSKIP("the window system would not expose a window (locked session?)");
        QVERIFY2(got.isValid(), "nothing rendered");
        QVERIFY2(got != Qt::white && got != Qt::black,
                 "invert produced a constant — the destination is not reaching the blend");
    }

    void multiplyScalesTheBackdrop() {
        // src 50% grey: dst * 0.5
        near(render(QStringLiteral("multiply"), QColor(128, 128, 128)),
             64 * 128 / 255, 32 * 128 / 255, 96 * 128 / 255, "multiply");
    }

    void lightenKeepsThePerChannelMaximum() {
        // max(src, dst) per channel, src 50% grey
        near(render(QStringLiteral("lighten"), QColor(128, 128, 128)),
             qMax(64, 128), qMax(32, 128), qMax(96, 128), "lighten");
    }

    void darkenKeepsThePerChannelMinimum() {
        near(render(QStringLiteral("darken"), QColor(128, 128, 128)),
             qMin(64, 128), qMin(32, 128), qMin(96, 128), "darken");
    }

    // Nothing behind it is still something. Over a transparent region a blend
    // draws the inverse of the black it is sitting on, opaque, like any other
    // surface. Preserving the destination alpha would compute the colour and
    // throw it away, and the surface would vanish.
    void aBlendOverATransparentGroundIsVisible() {
        QQuickWindow win;
        win.resize(kW, kH);
        win.setColor(QColor(0, 0, 0, 0));      // nothing behind it at all
        auto* b = new BlendItem;
        b->setParentItem(win.contentItem());
        b->setSize(QSizeF(kW, kH));
        b->setColor(Qt::white);
        b->setMode(QStringLiteral("invert"));
        win.show();
        if (!QTest::qWaitForWindowExposed(&win))
            QSKIP("the window system would not expose a window (locked session?)");
        QImage shot;
        for (int i = 0; i < 5 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
        QVERIFY2(!shot.isNull(), "nothing rendered");
        const QColor got = shot.pixelColor(kW / 2, kH / 2);
        QVERIFY2(got.alpha() > 250,
                 qPrintable(QStringLiteral("a blended surface must be opaque where it draws, "
                                           "got alpha %1").arg(got.alpha())));
        QVERIFY2(got.red() > 250 && got.green() > 250 && got.blue() > 250,
                 qPrintable(QStringLiteral("invert of black is white, got %1").arg(got.name())));
    }

    // Glyph materials cannot be blended, so a blended Text is a texture drawn
    // through this. A solid rectangle stands in so the pixel does not depend on
    // the installed font.
    void aTextureSourceBlendsWhatTheTextureHolds() {
        // layer.enabled provides the texture and still draws white, which this
        // inverts to black; drawing nothing leaves white and a flat fill
        // inverts the background.
        const QColor got = renderQml(QStringLiteral(
            "Rectangle { id: src; anchors.fill: parent; color: 'white'\n"
            "            layer.enabled: true }\n"
            "BlendRect { anchors.fill: parent; source: src; mode: 'invert' }"));
        if (!exposed_) QSKIP("the window system would not expose a window (locked session?)");
        near(got, 0, 0, 0, "invert of a white texture");
    }

    void aSourceThatProvidesNoTextureDrawsNothing() {
        const QColor got = renderQml(QStringLiteral(
            "Item { id: plain; anchors.fill: parent }\n"
            "BlendRect { anchors.fill: parent; source: plain; mode: 'invert' }"));
        if (!exposed_) QSKIP("the window system would not expose a window (locked session?)");
        near(got, bg().red(), bg().green(), bg().blue(), "non-provider source");
    }

    // The recipe for blending text: a source only has a texture if it renders
    // (layer.enabled at opacity 0, a hidden ShaderEffectSource and layer.effect
    // hand over nothing), but a rendering source also draws and the blend
    // inverts it. A zero-sized clipping parent satisfies both.
    void aClippedSourceBlendsTheBackgroundRatherThanItself() {
        const QColor got = renderQml(QStringLiteral(
            "Item { width: 0; height: 0; clip: true\n"
            "       Rectangle { id: s; width: 64; height: 64; color: 'white'\n"
            "                   layer.enabled: true } }\n"
            "BlendRect { anchors.fill: parent; source: s; mode: 'invert' }"));
        if (!exposed_) QSKIP("the window system would not expose a window (locked session?)");
        // the inverse of the background. Black would mean it inverted the
        // source's own white draw, which is what every visible recipe gives.
        near(got, 255 - 64, 255 - 32, 255 - 96, "clipped source, invert");
    }

    // huelum.frag and Theme.adapt() (the JS path for ~130 plain Text elements)
    // implement one formula; drift shows as a row title a different colour from
    // its label. Expectations are computed from the formula so the shader is
    // not pinned against itself.
    static QColor adaptRef(const QColor& c, double hue, double lum, double sat) {
        const double k = 0.57735027;
        const double ca = std::cos(hue * M_PI), sa = std::sin(hue * M_PI);
        const double r0 = c.redF(), g0 = c.greenF(), b0 = c.blueF();
        const double dot = k * (r0 + g0 + b0);
        auto cl = [](double x) { return qBound(0.0, x, 1.0); };
        const double r = cl(r0 * ca + (k * b0 - k * g0) * sa + k * dot * (1 - ca));
        const double g = cl(g0 * ca + (k * r0 - k * b0) * sa + k * dot * (1 - ca));
        const double b = cl(b0 * ca + (k * g0 - k * r0) * sa + k * dot * (1 - ca));
        // HSL, lightness moved, hue and saturation kept — the shader's maths
        const double mx = std::max({r, g, b}), mn = std::min({r, g, b});
        const double l = (mx + mn) / 2, d = mx - mn;
        double h = 0, s = 0;
        if (d > 1e-5) {
            s = l < 0.5 ? d / (mx + mn) : d / (2 - mx - mn);
            if (mx == r) h = (g - b) / d + (g < b ? 6 : 0);
            else if (mx == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h /= 6;
        }
        s = cl(s * (1 + sat));
        const double flip = l > 0.5 ? (1 - l) * (1 - l) : 1 - l * l;
        const double L2 = lum < 0 ? l + (1 - 2 * l) * (-lum) : l + (flip - l) * lum;
        if (s < 1e-5) return QColor::fromRgbF(L2, L2, L2);
        const double q = L2 < 0.5 ? L2 * (1 + s) : L2 + s - L2 * s;
        const double p = 2 * L2 - q;
        auto h2 = [](double pp, double qq, double t) {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0 / 6) return pp + (qq - pp) * 6 * t;
            if (t < 0.5) return qq;
            if (t < 2.0 / 3) return pp + (qq - pp) * (2.0 / 3 - t) * 6;
            return pp;
        };
        return QColor::fromRgbF(cl(h2(p, q, h + 1.0 / 3)), cl(h2(p, q, h)), cl(h2(p, q, h - 1.0 / 3)));
    }

    // HueLum over a flat colour, middle pixel.
    QColor renderAdaptive(const QColor& behind, double hue, double lum, double sat) {
        QQmlEngine engine;
        engine.addImportPath(QStringLiteral(MELO_QML_DIR));
        QQmlComponent comp(&engine);
        comp.setData(QStringLiteral(
            "import QtQuick\n"
            "import \"file://%5\" as C\n"
            "Item { width: %1; height: %2\n"
            "  Rectangle { id: ground; anchors.fill: parent; color: '%6' }\n"
            "  C.HueLum { anchors.fill: parent; backdrop: ground\n"
            "             hue: %3; lum: %4; sat: %7 }\n"
            "}").arg(kW).arg(kH).arg(hue).arg(lum)
               .arg(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/components"))
               .arg(behind.name()).arg(sat).toUtf8(),
            QUrl::fromLocalFile(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/probe.qml")));
        if (comp.isError()) { qWarning() << comp.errorString(); return QColor(); }
        auto* root = qobject_cast<QQuickItem*>(comp.create());
        if (!root) return QColor();
        QQuickWindow win;
        win.resize(kW, kH);
        win.setColor(Qt::black);
        root->setParentItem(win.contentItem());
        win.show();
        if (!QTest::qWaitForWindowExposed(&win)) { exposed_ = false; return QColor(); }
        QImage shot;
        for (int i = 0; i < 6 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
        if (shot.isNull()) return QColor();
        return shot.pixelColor(kW / 2, kH / 2);
    }

    void theShaderMatchesTheArithmeticThePlainReadersUse() {
        struct Case { const char* behind; double hue, lum, sat; };
        static const Case cases[] = {
            {"#3050a0",  0.0, -1.0,  0.0},   // plain inversion
            {"#3050a0",  0.0,  1.0,  0.0},   // the flip away from mid-grey
            {"#a03050",  0.5,  0.0,  0.0},   // hue only
            {"#a03050",  0.0,  0.0, -1.0},   // to grey
            {"#808080",  0.0, -1.0,  0.0},   // mid-grey inverts to itself
        };
        for (const Case& c : cases) {
            const QColor behind(QLatin1String(c.behind));
            const QColor got = renderAdaptive(behind, c.hue, c.lum, c.sat);
            if (!exposed_) QSKIP("compositor never exposed the window");
            QVERIFY2(got.isValid(), c.behind);
            const QColor want = adaptRef(behind, c.hue, c.lum, c.sat);
            const QString what = QStringLiteral("%1 h%2 l%3 s%4: shader %5 vs arithmetic %6")
                .arg(QLatin1String(c.behind)).arg(c.hue).arg(c.lum).arg(c.sat)
                .arg(got.name(), want.name());
            // 3/255 covers the shader's float path against JS doubles
            QVERIFY2(qAbs(got.red() - want.red()) <= 3
                     && qAbs(got.green() - want.green()) <= 3
                     && qAbs(got.blue() - want.blue()) <= 3, qPrintable(what));
        }
    }

    // Theme.backdrop is one layer texture sampled with a sub-rect, so a surface
    // reads the ground beneath it. Over a vertical gradient a surface a quarter
    // down reads quarter grey, and three quarters after moving: this pins the
    // sub-rect, orientation and per-frame recompute.
    void theSharedGroundIsSampledWhereTheSurfaceIs() {
        QQmlEngine engine;
        QQmlComponent comp(&engine);
        comp.setData(QStringLiteral(
            "import QtQuick\n"
            "import \"file://%3\" as C\n"
            "Item { width: %1; height: %2\n"
            "  Item { id: ground; anchors.fill: parent; layer.enabled: true\n"
            "    Rectangle { anchors.fill: parent\n"
            "      gradient: Gradient {\n"
            "        GradientStop { position: 0; color: '#000000' }\n"
            "        GradientStop { position: 1; color: '#ffffff' } } } }\n"
            "  C.HueLum { objectName: 'hl'; x: 0; y: %4; width: %1; height: 8\n"
            "             backdrop: ground; hue: 0; lum: 0; sat: 0 }\n"
            "}").arg(kW).arg(kH)
               .arg(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/components"))
               .arg(kH / 4 - 4).toUtf8(),
            QUrl::fromLocalFile(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/probe.qml")));
        QVERIFY2(!comp.isError(), qPrintable(comp.errorString()));
        auto* root = qobject_cast<QQuickItem*>(comp.create());
        QVERIFY(root);
        auto* hl = root->findChild<QQuickItem*>(QStringLiteral("hl"));
        QVERIFY(hl);
        QQuickWindow win;
        win.resize(kW, kH);
        win.setColor(Qt::black);
        root->setParentItem(win.contentItem());
        win.show();
        if (!QTest::qWaitForWindowExposed(&win)) QSKIP("compositor never exposed the window");

        // grabWindow returns DEVICE pixels; on a scaled desktop a logical y
        // lands on the wrong row (at 1.9x, a quarter reads as an eighth)
        auto grabAt = [&](int y) -> int {
            QImage shot;
            for (int i = 0; i < 6 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
            if (shot.isNull()) return -1;
            return qGray(shot.pixel(shot.width() / 2, y * shot.height() / kH));
        };
        // the surface's middle row is at y+4; the gradient there is that
        // fraction of the way from black to white
        const int q1 = grabAt(kH / 4);
        QVERIFY2(q1 >= 0, "nothing rendered");
        QVERIFY2(qAbs(q1 - 64) <= 12,
                 qPrintable(QStringLiteral("a quarter down read %1, expected ~64 — a flipped or "
                                           "top-left sample would read ~191 or ~0").arg(q1)));
        // MOVE IT. mapToItem is not reactive; the per-frame recompute is.
        hl->setY(3 * kH / 4 - 4);
        QTest::qWait(60);
        const int q3 = grabAt(3 * kH / 4);
        QVERIFY2(qAbs(q3 - 191) <= 12,
                 qPrintable(QStringLiteral("three quarters down read %1, expected ~191 — a stale "
                                           "rect would still read ~64").arg(q3)));
    }

    // A glyph layer's RGB carries subpixel fringes; read as colour, blended
    // words light about 15% more pixels than plain ones. BlendText reads
    // coverage; this compares lit pixels both ways.
    void blendedTextLightsNoMorePixelsThanPlainText() {
        const int w = 360, h = 40;
        auto count = [&](const QString& qml) -> int {
            QQmlEngine engine;
            QQmlComponent comp(&engine);
            comp.setData(qml.toUtf8(),
                QUrl::fromLocalFile(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/probe.qml")));
            if (comp.isError()) { qWarning() << comp.errorString(); return -1; }
            auto* root = qobject_cast<QQuickItem*>(comp.create());
            if (!root) return -1;
            QQuickWindow win;
            win.resize(w, h);
            win.setColor(QColor("#1b2230"));
            root->setParentItem(win.contentItem());
            win.show();
            if (!QTest::qWaitForWindowExposed(&win)) { exposed_ = false; return -1; }
            QImage shot;
            for (int i = 0; i < 6 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
            if (shot.isNull()) return -1;
            int lit = 0;
            for (int y = 0; y < shot.height(); ++y)
                for (int x = 0; x < shot.width(); ++x)
                    if (qGray(shot.pixel(x, y)) > 60) ++lit;
            return lit;
        };
        const QString font = QStringLiteral("font { pixelSize: 22; family: 'Red Hat Display'; weight: 500 }");
        const int plain = count(QStringLiteral(
            "import QtQuick\nItem { width: %1; height: %2\n"
            "  Text { x: 8; y: 6; text: 'Blended Words Title'; color: '#e0e0e0'; %3 } }")
            .arg(w).arg(h).arg(font));
        const int blended = count(QStringLiteral(
            "import QtQuick\nimport \"file://%4\" as C\nItem { width: %1; height: %2\n"
            "  C.BlendText { x: 8; y: 6; width: 340; height: 30; blend: 'normal'\n"
            "                text: 'Blended Words Title'; color: '#e0e0e0'; %3 } }")
            .arg(w).arg(h).arg(font).arg(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/components")));
        if (!exposed_) QSKIP("compositor never exposed the window");
        QVERIFY2(plain > 100 && blended > 100,
                 qPrintable(QStringLiteral("plain %1 blended %2 — one of them did not render")
                            .arg(plain).arg(blended)));
        // One-sided: linear filtering at a fractional offset spreads the glyphs,
        // while Nearest lights a few percent fewer. Only growth fails; the floor
        // proves the words rendered.
        QVERIFY2(blended * 100 <= plain * 104,
                 qPrintable(QStringLiteral("blended text lit %1 pixels, plain %2: a spread means "
                                           "the mask is being resampled — check the sampler's "
                                           "filtering against the texture's scale")
                            .arg(blended).arg(plain)));
        QVERIFY2(blended * 100 >= plain * 85,
                 qPrintable(QStringLiteral("blended text lit only %1 of plain's %2 pixels")
                            .arg(blended).arg(plain)));
    }

    // The outline is as wide as it says: with a red outline the red must start
    // about `size` left of the plain words' leftmost column. 1.5px covers the
    // offset-copies path, 5px the blur-and-cut path.
    int leftmostLit(QQuickWindow& win, bool red) {
        QImage shot;
        for (int i = 0; i < 8 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(30); }
        if (shot.isNull()) return -1;
        for (int x = 0; x < shot.width(); ++x)
            for (int y = 0; y < shot.height(); ++y) {
                const QColor c = shot.pixelColor(x, y);
                if (red ? (c.red() > 100 && c.green() < 60) : (c.red() > 100 && c.green() > 100)) return x;
            }
        return -1;
    }
    void theOutlineExtendsTheWordsByItsSize() {
        struct Case { double size; const char* path; };
        for (const Case& c : { Case{1.5, "offset copies"}, Case{3.0, "blur and cut"},
                               Case{5.0, "blur and cut"}, Case{8.0, "blur and cut"} }) {
            QQmlEngine engine;
            QQmlComponent comp(&engine);
            comp.setData(QStringLiteral(
                "import QtQuick\nimport \"file://%3\" as C\n"
                "Item { width: %1; height: %2\n"
                "  Text { id: t; x: 30; y: 4; text: 'HH'; color: 'white'\n"
                "         font { pixelSize: 40; weight: 700; family: 'Red Hat Display' } }\n"
                "  C.TextHalo { objectName: 'halo'; label: t; colour: 'red'\n"
                "               effect: ({ kind: 'outline', size: %4, soft: 0, dx: 0, dy: 0,\n"
                "                          colour: '#ff0000', opacity: 1 }) }\n"
                "}").arg(kW * 2).arg(kH)
                   .arg(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/components")).arg(c.size).toUtf8(),
                QUrl::fromLocalFile(QStringLiteral(MELO_QML_DIR) + QStringLiteral("/probe.qml")));
            QVERIFY2(!comp.isError(), qPrintable(comp.errorString()));
            auto* root = qobject_cast<QQuickItem*>(comp.create());
            QVERIFY(root);
            auto* halo = root->findChild<QQuickItem*>(QStringLiteral("halo"));
            QVERIFY(halo);
            QQuickWindow win;
            win.resize(kW * 2, kH);
            win.setColor(Qt::black);
            root->setParentItem(win.contentItem());
            win.show();
            if (!QTest::qWaitForWindowExposed(&win)) QSKIP("compositor never exposed the window");
            const double k = double(win.grabWindow().width()) / (kW * 2);
            halo->setVisible(false);
            const int plain = leftmostLit(win, false);
            halo->setVisible(true);
            const int haloed = leftmostLit(win, true);
            QVERIFY2(plain > 0 && haloed > 0, qPrintable(QStringLiteral("%1: nothing rendered").arg(c.path)));
            // sizes are relative to the type: a unit is 6% of the 40px font
            const double want = c.size * 40 * 0.06;
            const double grew = (plain - haloed) / k;   // logical px the red begins before the white
            QVERIFY2(grew >= want * 0.6 && grew <= want * 1.5,
                     qPrintable(QStringLiteral("%1 at size %2: red begins %3px before the words, expected about %4")
                                .arg(QLatin1String(c.path)).arg(c.size).arg(grew, 0, 'f', 1).arg(want, 0, 'f', 1)));
        }
    }

    // A mask makes a text shape: letters are cut from existing content and the
    // background shows through. An unrendered mask source (a solid block) and
    // content that draws nothing both fail the coverage check.
    void anOpacityMaskProducesATextShape() {
        const int w = 320, h = 90;
        QQmlEngine engine;
        QQmlComponent comp(&engine);
        comp.setData(QStringLiteral(
            "import QtQuick\nimport Qt5Compat.GraphicalEffects\n"
            "Item { width: %1; height: %2\n"
            "  Text { id: m; anchors.fill: parent\n"
            "         horizontalAlignment: Text.AlignHCenter\n"
            "         verticalAlignment: Text.AlignVCenter\n"
            "         text: 'MELO'; font.pixelSize: 64; font.bold: true\n"
            "         color: 'white'; visible: false; layer.enabled: true }\n"
            "  Item { anchors.fill: parent; layer.enabled: true\n"
            "         layer.effect: OpacityMask { maskSource: m; invert: false }\n"
            "         Rectangle { anchors.fill: parent; color: 'white' } }\n"
            "}").arg(w).arg(h).toUtf8(), QUrl());
        QVERIFY2(!comp.isError(), qPrintable(comp.errorString()));
        auto* root = qobject_cast<QQuickItem*>(comp.create());
        QVERIFY(root);
        QQuickWindow win;
        win.resize(w, h);
        win.setColor(QColor(0, 0, 0));
        root->setParentItem(win.contentItem());
        win.show();
        if (!QTest::qWaitForWindowExposed(&win)) {
            delete root;
            QSKIP("the window system would not expose a window (locked session?)");
        }
        QImage shot;
        for (int i = 0; i < 6 && shot.isNull(); ++i) { shot = win.grabWindow(); QTest::qWait(20); }
        QVERIFY2(!shot.isNull(), "nothing rendered");

        int lit = 0, total = 0;
        for (int y = 0; y < shot.height(); ++y)
            for (int x = 0; x < shot.width(); ++x) {
                ++total;
                const QColor p = shot.pixelColor(x, y);
                if (p.red() + p.green() + p.blue() > 380) ++lit;
            }
        const int pct = total ? lit * 100 / total : -1;
        delete root;

        QVERIFY2(pct > 3, qPrintable(QStringLiteral(
            "the mask kept %1%% — an empty mask keeps nothing and the caller gets a "
            "hole where the words should be").arg(pct)));
        QVERIFY2(pct < 40, qPrintable(QStringLiteral(
            "the mask kept %1%% — that is a block, not letters; the mask is not "
            "reaching the effect").arg(pct)));
    }

    // A name nobody implements must draw NOTHING, so a typo in a theme shows
    // as the missing surface it is rather than as a plausible normal fill.
    void anUnknownModeDrawsNothing() {
        near(render(QStringLiteral("mix-blend-overlay-please"), Qt::white),
             bg().red(), bg().green(), bg().blue(), "unknown mode");
        QVERIFY(!BlendItem::supportsMode(QStringLiteral("mix-blend-overlay-please")));
        QVERIFY(BlendItem::supportsMode(QStringLiteral("invert")));
    }
};

QTEST_MAIN(TestBlendModes)
#include "tst_blendmodes.moc"
