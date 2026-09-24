// Window shaping from region.txt: MeloUi.window[id].setShape(polygons).
// Under test:
//   1. Accumulation: region.txt quads overlap to round corners, so first-only,
//      last-only or bounding-box bugs look plausible; assertions name points
//      inside one quad and outside the others. Keep the test polygons
//      overlapping.
//   2. Hostile input: setShape is plugin-reachable; a broken region.txt gives a
//      rectangular window, never a failed load or a hang.
//   3. Shape and the silence rule share QWindow::setMask; applied independently
//      each wipes the other at the next show/hide.
#include <QtTest>
#include <QGuiApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QMetaMethod>
#include <QMetaProperty>
#include <QPolygon>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QRegion>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <QWindow>
#include <memory>

#include "MeloUi.h"
#include "PluginUiHost.h"
#include "PluginWindowHost.h"

// ---------------------------------------------------------------------------
// A region.txt shape as a plugin would hand it over: one flat coordinate list
// per polygon, which is what a PointList= line parses to.
// ---------------------------------------------------------------------------
static QVariantList quad(int x1, int y1, int x2, int y2, int x3, int y3, int x4, int y4) {
    return QVariantList{ x1, y1, x2, y2, x3, y3, x4, y4 };
}

// main: seven quads
static QVariantList normalShape() {
    return QVariantList{
        QVariant(quad(  7,  0, 268,  0, 268, 114,   7, 114)),
        QVariant(quad(  4,  1, 271,  1, 271, 113,   4, 113)),
        QVariant(quad(  2,  3, 273,  3, 273, 112,   2, 112)),
        QVariant(quad(  1,  4, 274,  4, 274, 111,   1, 111)),
        QVariant(quad(  0,  7, 275,  7, 275, 108,   0, 108)),
        QVariant(quad(  3, 113, 272, 113, 272, 115,   3, 115)),
        QVariant(quad(  8, 115, 267, 115, 267, 116,   8, 116)),
    };
}

// eq: six quads
static QVariantList equalizerShape() {
    return QVariantList{
        QVariant(quad(  8,  0, 267,  0, 267, 116,   8, 116)),
        QVariant(quad(  5,  1, 270,  1, 270, 115,   5, 115)),
        QVariant(quad(  3,  2, 272,  2, 272, 114,   3, 114)),
        QVariant(quad(  2,  4, 273,  4, 273, 113,   2, 113)),
        QVariant(quad(  1,  6, 274,  6, 274, 111,   1, 111)),
        QVariant(quad(  0,  9, 275,  9, 275, 108,   0, 108)),
    };
}

// The same seven quads, built here with Qt's own primitives rather than through
// the code under test. An expectation the implementation computes for itself
// would agree with any bug it happens to have.
static QRegion expectedNormal() {
    const int q[7][8] = {
        {  7,   0, 268,   0, 268, 114,   7, 114 },
        {  4,   1, 271,   1, 271, 113,   4, 113 },
        {  2,   3, 273,   3, 273, 112,   2, 112 },
        {  1,   4, 274,   4, 274, 111,   1, 111 },
        {  0,   7, 275,   7, 275, 108,   0, 108 },
        {  3, 113, 272, 113, 272, 115,   3, 115 },
        {  8, 115, 267, 115, 267, 116,   8, 116 },
    };
    QRegion r;
    for (const auto& c : q) {
        QPolygon p;
        for (int i = 0; i < 4; ++i) p << QPoint(c[i * 2], c[i * 2 + 1]);
        r += QRegion(p);
    }
    return r;
}

// ---------------------------------------------------------------------------
// A plugin on disk, with two windows. Small on purpose: nothing here is about
// what the plugin DRAWS.
// ---------------------------------------------------------------------------
struct PluginFixture {
    QTemporaryDir dir;
    std::unique_ptr<MeloUi> bridge;
    std::unique_ptr<PluginUiHost> ui;
    std::unique_ptr<PluginWindowHost> host;

    bool write(const QString& rel, const QByteArray& body) {
        QFile f(QDir(dir.path()).filePath(rel));
        return f.open(QIODevice::WriteOnly) && f.write(body) == body.size();
    }

    bool build() {
        if (!dir.isValid()) return false;
        if (!write(QStringLiteral("window.qml"),
                   "import QtQuick\nRectangle { color: \"#202020\" }\n")) return false;
        // Every dependency of MeloUi is null: this test drives the WINDOW side,
        // and a facade with no player/queue/sidecar behind it answers with its
        // documented empty values rather than crashing.
        bridge = std::make_unique<MeloUi>(QStringLiteral("shaper"), dir.path(),
                                          nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
        ui = std::make_unique<PluginUiHost>(QStringLiteral("shaper"), dir.path(),
                                            bridge.get());
        if (!ui->engine()) return false;
        if (!ui->load(QString())) return false;
        // wc = nullptr: no KWin here; the host guards every use, and owns the
        // mask itself. spectrum = nullptr also asserts a host with no arbiter
        // is inert through every setActive() below.
        host = std::make_unique<PluginWindowHost>(ui.get(), bridge.get(), nullptr, nullptr,
                                                  nullptr);
        QJsonObject uiBlock{
            {QStringLiteral("windows"), QJsonArray{
                QJsonObject{{QStringLiteral("id"), QStringLiteral("main")},
                            {QStringLiteral("qml"), QStringLiteral("window.qml")},
                            {QStringLiteral("width"), 275},
                            {QStringLiteral("height"), 116},
                            {QStringLiteral("primary"), true}},
                QJsonObject{{QStringLiteral("id"), QStringLiteral("eq")},
                            {QStringLiteral("qml"), QStringLiteral("window.qml")},
                            {QStringLiteral("width"), 275},
                            {QStringLiteral("height"), 116}}}}};
        return host->build(uiBlock);
    }

    // The real QQuickWindow behind a facade, found the way anything outside the
    // host can find it: by the caption the host registered. There is no
    // accessor, and adding one for a test would widen the shell's surface.
    QWindow* window(const QString& id) const {
        const QString title = QStringLiteral("melo-plugin-shaper-%1").arg(id);
        for (QWindow* w : QGuiApplication::topLevelWindows())
            if (w->title() == title) return w;
        return nullptr;
    }

    MeloUiWindow* facade(const QString& id) const {
        return qobject_cast<MeloUiWindow*>(
            bridge->window().value(id).value<QObject*>());
    }
};

class TstWindowShape : public QObject {
    Q_OBJECT

    PluginFixture fx;
    // A window in this process that the host did NOT create. Without one, the
    // "nothing outside this host was touched" loop in test 10 iterates zero
    // windows and cannot fail.
    std::unique_ptr<QQuickWindow> foreign;

    // The region every shape assertion is measured against while the window is
    // silenced: WindowController::setInputEnabled(false)'s off-surface 1x1.
    static QRegion offSurface() { return QRegion(-100, -100, 1, 1); }

private slots:
    void initTestCase() {
        QVERIFY2(fx.build(), qPrintable(fx.host ? fx.host->errorString()
                                                : QStringLiteral("fixture setup failed")));
        QVERIFY(fx.window(QStringLiteral("main")));
        QVERIFY(fx.window(QStringLiteral("eq")));
        QVERIFY(fx.facade(QStringLiteral("main")));
        foreign = std::make_unique<QQuickWindow>();
        foreign->setTitle(QStringLiteral("not-a-melo-plugin-window"));
        foreign->resize(275, 116);
        foreign->setVisible(true);
        QVERIFY(foreign->mask().isEmpty());
        // Every test below assumes the group is ACTIVE, because that is the
        // only state in which a shape is the thing on the mask at all.
        fx.host->setActive(true, false);
    }

    void init() {
        // Each test starts from "no shape": a leftover from the previous one
        // would let a broken clear path pass by accident.
        fx.facade(QStringLiteral("main"))->setShape(QVariantList());
        fx.facade(QStringLiteral("eq"))->setShape(QVariantList());
        fx.host->setActive(true, false);
    }

    // 1. Seven overlapping quads accumulate. Not "a region appears" — the
    //    exact region Qt produces from the same seven polygons.
    void aSevenQuadShapeAccumulatesAcrossAllSevenQuads() {
        auto* w = fx.window(QStringLiteral("main"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());

        const QRegion got = w->mask();
        const QRegion want = expectedNormal();
        QVERIFY(!got.isEmpty());
        QCOMPARE(got.boundingRect(), QRect(0, 0, 275, 116));
        // Measured, not assumed: ten rects, from seven overlapping quads.
        QCOMPARE(got.rectCount(), 10);
        QCOMPARE(got, want);

        // Points that separate accumulation from every cheaper answer.
        // (0,7) is reachable only through quad 5; a first-quad-only or
        // last-quad-only implementation misses it.
        QVERIFY(got.contains(QPoint(0, 7)));
        QVERIFY(got.contains(QPoint(1, 4)));      // quad 4 only
        QVERIFY(got.contains(QPoint(7, 0)));      // quad 1 only
        QVERIFY(got.contains(QPoint(8, 115)));    // quad 7 only
        QVERIFY(got.contains(QPoint(137, 58)));   // the middle, in every quad
        // ...and the corners the union deliberately does NOT cover. A
        // bounding-box implementation includes all four.
        QVERIFY(!got.contains(QPoint(0, 0)));
        QVERIFY(!got.contains(QPoint(0, 6)));
        QVERIFY(!got.contains(QPoint(274, 0)));
        QVERIFY(!got.contains(QPoint(274, 108)));
    }

    // 2. The two sections really are different shapes, and the window that was
    //    not asked keeps its own. A host that shaped "whatever window it found"
    //    would pass every assertion in test 1.
    void eachWindowKeepsItsOwnShape() {
        auto* main = fx.window(QStringLiteral("main"));
        auto* eq = fx.window(QStringLiteral("eq"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());
        QVERIFY(eq->mask().isEmpty());            // untouched by main's call

        fx.facade(QStringLiteral("eq"))->setShape(equalizerShape());
        QCOMPARE(main->mask(), expectedNormal()); // still main's own
        QVERIFY(eq->mask() != main->mask());
        QCOMPARE(eq->mask().rectCount(), 11);
        // eq's outermost quad starts two rows lower than main's.
        QVERIFY(main->mask().contains(QPoint(0, 7)));
        QVERIFY(!eq->mask().contains(QPoint(0, 7)));
        QVERIFY(eq->mask().contains(QPoint(0, 9)));
    }

    // 3. `[]` clears.
    void anEmptyListClearsTheMask() {
        auto* w = fx.window(QStringLiteral("main"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());
        QVERIFY(!w->mask().isEmpty());
        fx.facade(QStringLiteral("main"))->setShape(QVariantList());
        QVERIFY(w->mask().isEmpty());
    }

    // 4. Hostile and broken input: every row leaves the window rectangular
    //    without throwing or hanging. QRegion(QPolygon) scan-converts, so the
    //    time bound catches absurdly large coordinates.
    void malformedInputIsIgnoredAndLeavesTheWindowRectangular_data() {
        QTest::addColumn<QVariantList>("polygons");
        // How many of them the shell must REPORT as unusable. An empty mask
        // alone is a weak assertion: a polygon of one point produces an empty
        // region whether it was rejected or accepted, so without this column
        // the "fewer than three corners" rule is unfalsifiable.
        QTest::addColumn<int>("dropped");

        QTest::newRow("odd coordinate count")
            << QVariantList{ QVariant(QVariantList{ 5, 0, 270, 0, 270 }) } << 1;
        // Seven coordinates: rounding the count down leaves THREE valid corners
        // and a triangle across the window. Without this row the odd-count
        // check is unfalsifiable too — the five-coordinate row above passes
        // with or without it, because rounding it down leaves too few corners.
        QTest::newRow("odd coordinate count, would-be triangle")
            << QVariantList{ QVariant(QVariantList{ 5, 0, 270, 0, 270, 115, 5 }) } << 1;
        QTest::newRow("non-numeric")
            << QVariantList{ QVariant(QVariantList{ QStringLiteral("five"), QStringLiteral("oh"),
                                                    QStringLiteral("a"), QStringLiteral("b"),
                                                    QStringLiteral("c"), QStringLiteral("d") }) } << 1;
        QTest::newRow("absurdly large")
            << QVariantList{ QVariant(QVariantList{ 0.0, 0.0, 1e12, 0.0,
                                                    1e12, 1e12, 0.0, 1e12 }) } << 1;
        QTest::newRow("infinite")
            << QVariantList{ QVariant(QVariantList{ 0.0, 0.0,
                                                    std::numeric_limits<double>::infinity(), 0.0,
                                                    10.0, 10.0, 0.0, 10.0 }) } << 1;
        QTest::newRow("not a number")
            << QVariantList{ QVariant(QVariantList{ 0.0, 0.0,
                                                    std::numeric_limits<double>::quiet_NaN(), 0.0,
                                                    10.0, 10.0, 0.0, 10.0 }) } << 1;
        QTest::newRow("empty polygon") << QVariantList{ QVariant(QVariantList{}) } << 1;
        QTest::newRow("one point") << QVariantList{ QVariant(QVariantList{ 5, 0 }) } << 1;
        QTest::newRow("two points") << QVariantList{ QVariant(QVariantList{ 5, 0, 270, 0 }) } << 1;
        QTest::newRow("polygon is not a list") << QVariantList{ QVariant(7) } << 1;
        QTest::newRow("polygon is a string")
            << QVariantList{ QVariant(QStringLiteral("5,0 270,0")) } << 1;
        QTest::newRow("nested one level too deep")
            << QVariantList{ QVariant(QVariantList{ QVariant(normalShape()) }) } << 1;
        // Collinear corners: three real points enclosing no area at all. This
        // row is NOT malformed — it is a legal polygon whose region is empty,
        // so nothing is dropped and the window is rectangular anyway.
        QTest::newRow("degenerate, no area")
            << QVariantList{ QVariant(QVariantList{ 0, 0, 10, 0, 20, 0 }) } << 0;
    }

    void malformedInputIsIgnoredAndLeavesTheWindowRectangular() {
        QFETCH(QVariantList, polygons);
        QFETCH(int, dropped);
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        // Start from a real shape, so "the mask is empty afterwards" can only
        // mean the bad input CLEARED it, never that nothing ever set it.
        f->setShape(normalShape());
        QVERIFY(!w->mask().isEmpty());

        QElapsedTimer t;
        t.start();
        f->setShape(polygons);
        const qint64 ms = t.elapsed();

        QVERIFY(w->mask().isEmpty());
        QVERIFY2(ms < 2000, qPrintable(QStringLiteral("setShape took %1ms").arg(ms)));

        int reported = -1;
        PluginWindowHost::shapeRegion(polygons, &reported);
        QCOMPARE(reported, dropped);
    }

    // 5. A negative coordinate is NOT malformed — it is off-surface. Rejecting
    //    it would be the bounding-box assumption this API must not make: real
    //    region.txt files run past the window's own size in both directions.
    void negativeAndOversizeCoordinatesAreShapeNotError() {
        auto* w = fx.window(QStringLiteral("main"));
        // A quad hanging off the top-left corner, plus one real quad.
        fx.facade(QStringLiteral("main"))->setShape(QVariantList{
            QVariant(quad(-40, -40, 40, -40, 40, 40, -40, 40)),
            QVariant(quad(100, 10, 200, 10, 200, 100, 100, 100)),
        });
        const QRegion got = w->mask();
        QVERIFY(!got.isEmpty());
        QVERIFY(got.contains(QPoint(-10, -10)));
        QVERIFY(got.contains(QPoint(150, 50)));
        QCOMPARE(got.boundingRect(), QRect(-40, -40, 240, 140));
    }

    // 6. One unusable quad does not throw away the six good ones: a malformed
    //    point invalidates its own polygon, never the whole shape, because re-linking an outline around a missing
    //    corner would produce a different shape and call it success.
    void oneBadQuadDropsOnlyItself() {
        auto* w = fx.window(QStringLiteral("main"));
        QVariantList polys = normalShape();
        polys[3] = QVariant(QVariantList{ 1, 4, 274, 4, 274 });     // odd count
        fx.facade(QStringLiteral("main"))->setShape(polys);

        QRegion want;
        QVariantList good = normalShape();
        good.removeAt(3);
        for (const QVariant& p : good) {
            const QVariantList c = p.toList();
            QPolygon poly;
            for (int i = 0; i < c.size(); i += 2)
                poly << QPoint(c.at(i).toInt(), c.at(i + 1).toInt());
            want += QRegion(poly);
        }
        QCOMPARE(w->mask(), want);
        QVERIFY(w->mask() != expectedNormal());   // the dropped quad really is gone
        QVERIFY(!w->mask().contains(QPoint(1, 4)));
        QVERIFY(w->mask().contains(QPoint(2, 3)));
    }

    // 7. Points as objects and as pairs, not only as a flat list. A plugin
    //    parsing region.txt in JS naturally produces one of the three.
    void pointsMayBeObjectsOrPairsOrAFlatList() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        const QRegion want = QRegion(QRect(5, 0, 265, 115));

        f->setShape(QVariantList{ QVariant(quad(5, 0, 270, 0, 270, 115, 5, 115)) });
        QCOMPARE(w->mask(), want);

        f->setShape(QVariantList());
        f->setShape(QVariantList{ QVariant(QVariantList{
            QVariant(QVariantList{ 5, 0 }), QVariant(QVariantList{ 270, 0 }),
            QVariant(QVariantList{ 270, 115 }), QVariant(QVariantList{ 5, 115 }) }) });
        QCOMPARE(w->mask(), want);

        auto pt = [](int x, int y) {
            return QVariant(QVariantMap{{QStringLiteral("x"), x}, {QStringLiteral("y"), y}});
        };
        f->setShape(QVariantList());
        f->setShape(QVariantList{ QVariant(QVariantList{
            pt(5, 0), pt(270, 0), pt(270, 115), pt(5, 115) }) });
        QCOMPARE(w->mask(), want);
    }

    // 8. The shared mechanism. The silence rule and the shape are both
    //    QWindow::setMask. A silenced window must be click-through whatever
    //    shape it carries, and the shape must come back when it is shown again
    //    — not be wiped by the state change.
    void theSilenceRuleOutranksTheShapeAndTheShapeSurvivesIt() {
        auto* w = fx.window(QStringLiteral("main"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());
        QCOMPARE(w->mask(), expectedNormal());

        fx.host->setActive(false, false);
        QCOMPARE(w->mask(), offSurface());        // click-through wins while silent

        fx.host->setActive(true, false);
        QCOMPARE(w->mask(), expectedNormal());    // and the shape is back, intact
    }

    // 9. Same collision through the other door: hiding a SIBLING window runs
    //    applyState over the whole set, which is where an independently-applied
    //    mask gets wiped.
    void aSiblingsShowHideDoesNotWipeTheShape() {
        auto* w = fx.window(QStringLiteral("main"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());
        fx.facade(QStringLiteral("eq"))->hide();
        QCOMPARE(w->mask(), expectedNormal());
        QCOMPARE(fx.window(QStringLiteral("eq"))->mask(), offSurface());
        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(w->mask(), expectedNormal());
        QVERIFY(fx.window(QStringLiteral("eq"))->mask().isEmpty());
    }

    // 10. An id this host did not create changes nothing. The facade never
    //     lets a plugin supply one (test 12 pins that); this is the second
    //     gate, in the host, for anything that reaches the backend directly.
    void shapingAnIdTheHostDoesNotOwnChangesNothing() {
        auto* main = fx.window(QStringLiteral("main"));
        auto* eq = fx.window(QStringLiteral("eq"));
        fx.facade(QStringLiteral("main"))->setShape(normalShape());

        auto* backend = static_cast<PluginWindowBackend*>(fx.host.get());
        for (const QString& id : { QStringLiteral("nosuch"), QString(),
                                   QStringLiteral("melo"), QStringLiteral("MAIN") })
            backend->setPluginWindowShape(id, equalizerShape());

        QCOMPARE(main->mask(), expectedNormal());
        QVERIFY(eq->mask().isEmpty());
        // ...and no window outside this host was touched either. `foreign` is
        // what makes this loop able to fail.
        int outsiders = 0;
        for (QWindow* w : QGuiApplication::topLevelWindows())
            if (w != main && w != eq) { ++outsiders; QVERIFY(w->mask().isEmpty()); }
        QVERIFY2(outsiders > 0, "the loop above must actually iterate something");
        QVERIFY(foreign->mask().isEmpty());
    }

    // 11. The whole path, from plugin QML in the restricted engine. Everything
    //     above drives C++; this is the door a skin actually uses.
    void pluginQmlShapesItsOwnWindowThroughTheBridge() {
        auto* w = fx.window(QStringLiteral("main"));
        QQmlComponent c(fx.ui->engine());
        c.setData(R"(
import QtQuick
QtObject {
    property bool ok: false
    property string reachedParent: "unset"
    property bool forgedId: false
    Component.onCompleted: {
        var win = MeloUi.window["main"];
        // The facade's QObject parent is the shell's window host. If QML can
        // resolve it, setActive() and opacityEntries() are one hop away.
        reachedParent = String(win.parent);
        // There is no id parameter to aim at another window. Tried FIRST, so
        // the shape asserted afterwards cannot have been repaired by the real
        // call that follows.
        try { win.setShape("eq", [[0,0, 10,0, 10,10, 0,10]]); forgedId = true; }
        catch (e) { forgedId = false; }
        win.setShape([[7,0, 268,0, 268,114, 7,114],
                      [4,1, 271,1, 271,113, 4,113],
                      [2,3, 273,3, 273,112, 2,112],
                      [1,4, 274,4, 274,111, 1,111],
                      [0,7, 275,7, 275,108, 0,108],
                      [3,113, 272,113, 272,115, 3,115],
                      [8,115, 267,115, 267,116, 8,116]]);
        ok = true;
    }
})", QUrl());
        std::unique_ptr<QObject> obj(c.create());
        QVERIFY2(obj.get(), qPrintable(c.errorString()));
        QVERIFY(obj->property("ok").toBool());
        QCOMPARE(w->mask(), expectedNormal());
        QCOMPARE(obj->property("reachedParent").toString(), QStringLiteral("undefined"));
        // QML DOES let the extra argument through: it warns "Too many arguments,
        // ignoring 1" and calls setShape anyway, so the forged call SUCCEEDS as
        // a call. Asserted rather than left to the reader, because "it threw" is
        // the wrong reason to feel safe here.
        QCOMPARE(obj->property("forgedId").toBool(), true);
        // The containment is that the ignored argument was the only place an id
        // could have gone: the call still landed on this facade's own window,
        // and "eq" was read as a polygon list, which it is not.
        QVERIFY(fx.window(QStringLiteral("eq"))->mask().isEmpty());
    }

    // 12. The entire plugin-reachable surface of MeloUiWindow, read back from
    //     moc. A future addition fails here first.
    void mocSurfaceOfTheWindowFacadeIsExactlyThis() {
        const QMetaObject* mo = &MeloUiWindow::staticMetaObject;

        QStringList props;
        for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i)
            props << QString::fromLatin1(mo->property(i).name());
        QCOMPARE(props, (QStringList{ QStringLiteral("id"), QStringLiteral("x"),
                                      QStringLiteral("y"), QStringLiteral("width"),
                                      QStringLiteral("height"), QStringLiteral("visible"),
                                      QStringLiteral("shaded") }));

        QStringList methods;
        for (int i = mo->methodOffset(); i < mo->methodCount(); ++i)
            methods << QString::fromLatin1(mo->method(i).methodSignature());
        QCOMPARE(methods, (QStringList{
            QStringLiteral("changed()"),
            QStringLiteral("show()"), QStringLiteral("hide()"),
            QStringLiteral("toggleShade()"), QStringLiteral("startDrag()"),
            // A gesture: the manifest's `resize` block decides where the drag
            // stops, and there is deliberately no resize(w, h) beside this; see
            // MeloUi.h and
            // theWindowFacadeAsksForAResizeAndNeverNamesOne in tst_windowsnap.
            QStringLiteral("startResize()"),
            QStringLiteral("setShape(QVariantList)") }));

        // notifyChanged() is the shell's own door and must stay unreachable:
        // public, but neither a slot nor Q_INVOKABLE.
        QCOMPARE(mo->indexOfMethod("notifyChanged()"), -1);
        // setShape takes only the polygons; an id parameter would let a
        // plugin shape a window that is not its own.
        const QMetaMethod m = mo->method(mo->indexOfMethod("setShape(QVariantList)"));
        QCOMPARE(m.parameterCount(), 1);
        QCOMPARE(m.methodType(), QMetaMethod::Method);

        // The backend call itself is a plain virtual override, so it is not in
        // the host's metaobject either — which is what keeps it out of reach if
        // the host is ever exposed by some future route.
        QCOMPARE(PluginWindowHost::staticMetaObject.indexOfMethod(
                     "setPluginWindowShape(QString,QVariantList)"), -1);
    }

    // 13. An empty accumulated region clears the shape: QRegion() equals
    //     QRegion(0,0,0,0) and QWindow::setMask branches on isEmpty(), so the
    //     window goes back to rectangular instead of unclickable.
    void aShapeThatEnclosesNothingIsTheClearNotABrick() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        f->setShape(normalShape());
        QVERIFY(!w->mask().isEmpty());
        // Three collinear corners: a real polygon with three real points and no
        // area whatsoever.
        f->setShape(QVariantList{ QVariant(quad(0, 0, 10, 0, 20, 0, 30, 0)) });
        QVERIFY(w->mask().isEmpty());
        QCOMPARE(w->mask(), QRegion());
    }

    // 14. The POLYGON CAP, on its own. Four thousand ordinary quads — the shape
    //     a real region.txt is made of, so each costs one unit and the work
    //     budget never comes near it. What stops this is the 512-polygon cap.
    void anEnormousArgumentIsBoundedNotObeyed() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        QVariantList polys;
        for (int i = 0; i < 4000; ++i)
            polys << QVariant(quad(i % 200, 0, i % 200 + 40, 0,
                                   i % 200 + 40, 113, i % 200, 113));
        QElapsedTimer t;
        t.start();
        f->setShape(polys);
        QVERIFY2(t.elapsed() < 5000, qPrintable(QStringLiteral("took %1ms").arg(t.elapsed())));

        // Bounded, not refused: the 512 that got in still shaped the window. A
        // test that only watched the clock would pass against a setShape that
        // ignored its argument entirely.
        QVERIFY(!w->mask().isEmpty());
        int dropped = -1;
        PluginWindowHost::shapeRegion(polys, &dropped);
        QCOMPARE(dropped, 4000 - 512);
    }

    // 14b. The WORK BUDGET, on its own. These are not quads — 600 points over a
    //      113-row span is 300 x 113 = 33900 units each, past the whole budget,
    //      so not one of them gets in however few there are. The polygon cap
    //      would have admitted all sixteen.
    void anExpensivePolygonIsRefusedEvenWhenThereAreFewOfThem() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        QVariantList polys;
        for (int i = 0; i < 16; ++i) {
            QVariantList flat;
            for (int p = 0; p < 600; ++p) flat << (i % 200) + p % 7 << p % 113;
            polys << QVariant(flat);
        }
        f->setShape(polys);
        QVERIFY(w->mask().isEmpty());
        int dropped = -1;
        PluginWindowHost::shapeRegion(polys, &dropped);
        QCOMPARE(dropped, 16);
    }

    // 14c. The rectangle fast path, which every real skin takes, must match the
    //      scan converter. Rows easy to miss: a bowtie (corners on the bounding
    //      box, region two triangles) and a degenerate spike that passes both
    //      fast-path tests while enclosing nothing.
    void theRectangleShortcutAgreesWithTheScanConverter() {
        auto agrees = [](const QVariantList& flat) {
            QPolygon p;
            for (int i = 0; i < flat.size(); i += 2)
                p << QPoint(flat.at(i).toInt(), flat.at(i + 1).toInt());
            return PluginWindowHost::shapeRegion(QVariantList{ QVariant(flat) })
                   == QRegion(p);
        };
        QVERIFY(agrees(quad(5, 0, 270, 0, 270, 115, 5, 115)));        // clockwise
        QVERIFY(agrees(quad(5, 115, 270, 115, 270, 0, 5, 0)));        // anticlockwise
        QVERIFY(agrees(quad(270, 0, 270, 115, 5, 115, 5, 0)));        // rotated start
        QVERIFY(agrees(quad(-40, -40, 40, -40, 40, 40, -40, 40)));    // negative corner
        QVERIFY(agrees(quad(5, 0, 270, 115, 270, 0, 5, 115)));        // BOWTIE
        QVERIFY(agrees(quad(5, 0, 200, 30, 270, 115, 5, 115)));       // not a rectangle
        QVERIFY(agrees(quad(0, 0, 10, 0, 10, 7, 10, 0)));             // DEGENERATE SPIKE
        // ...and the spike is EMPTY, not merely "the two paths agree": a fast
        // path that agreed by making both sides wrong would pass the row above.
        QCOMPARE(PluginWindowHost::shapeRegion(
                     QVariantList{ QVariant(quad(0, 0, 10, 0, 10, 7, 10, 0)) }), QRegion());

        // The whole corner-assignment space the spike came out of: every quad
        // whose four corners are drawn from its bounding box's own four, with
        // repetition: all 256, where a hand-picked row covers one.
        const int cx[2] = { 0, 10 }, cy[2] = { 0, 7 };
        int checked = 0;
        for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b)
        for (int c = 0; c < 4; ++c) for (int d = 0; d < 4; ++d) {
            const int idx[4] = { a, b, c, d };
            QVariantList flat;
            QPolygon poly;
            for (const int i : idx) {
                flat << cx[i & 1] << cy[(i >> 1) & 1];
                poly << QPoint(cx[i & 1], cy[(i >> 1) & 1]);
            }
            if (poly.boundingRect() != QRect(0, 0, 11, 8)) continue;   // does not span the box
            ++checked;
            QVERIFY2(PluginWindowHost::shapeRegion(QVariantList{ QVariant(flat) }) == QRegion(poly),
                     qPrintable(QStringLiteral("corner assignment %1,%2,%3,%4 disagrees with the "
                                               "scan converter").arg(a).arg(b).arg(c).arg(d)));
        }
        QVERIFY2(checked > 0, "the sweep above must actually check something");
    }

    // 15. The worst case the caps permit: a comb, whose teeth every scanline
    //     crosses, costs one rect per tooth per row (1023 points over 4096
    //     rows took 8.7s, a zig-zag 30ms). This builds the costliest comb the
    //     work budget admits and bounds its time; `dropped == 0` keeps that
    //     bound from passing on a refused argument.
    void theWorstCaseTheCapsPermitStaysInBudget() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));

        // work = ceil(points/2) * boundingRect().height(). 8 teeth = 16 points
        // over rows 0..4095 is 8 * 4096 = 32768 — the budget exactly, so this is
        // the largest comb that gets in rather than merely a large one.
        const int span = 4095, teeth = 8, width = 30000;
        QVariantList flat;
        for (int i = 0; i < teeth; ++i) {
            const int x = (i * width) / teeth;
            flat << x << 0 << x << span;
        }
        const QVariantList polys{ QVariant(flat) };

        int dropped = -1;
        QElapsedTimer t;
        t.start();
        f->setShape(polys);
        const qint64 ms = t.elapsed();
        PluginWindowHost::shapeRegion(polys, &dropped);

        QCOMPARE(dropped, 0);              // it really was admitted
        QVERIFY(!w->mask().isEmpty());     // ...and really was converted
        // A generous multiple of the ~150ms measured, not a tight budget: a
        // threshold that fires on a loaded runner is a flake, not a guard.
        QVERIFY2(ms < 1500, qPrintable(QStringLiteral(
            "the worst shape the caps admit took %1ms (rects=%2)")
            .arg(ms).arg(w->mask().rectCount())));

        // The same comb one step past the budget is refused outright rather
        // than costing more.
        QVariantList over = flat;
        over << (width + 1) << 0 << (width + 1) << span;
        int droppedOver = -1;
        PluginWindowHost::shapeRegion(QVariantList{ QVariant(over) }, &droppedOver);
        QCOMPARE(droppedOver, 1);
    }

    // 16. A mask does not follow a resize. toggleShade() makes the window
    //     275x14 and leaves the full-height region on it, deliberately: a
    //     skin's shaded mode has its own outline in region.txt.
    void aResizeDoesNotReDeriveTheShape() {
        auto* w = fx.window(QStringLiteral("main"));
        auto* f = fx.facade(QStringLiteral("main"));
        f->setShape(normalShape());
        const QRegion before = w->mask();
        QCOMPARE(before, expectedNormal());

        w->resize(275, 14);
        QCOMPARE(w->height(), 14);
        QCOMPARE(w->mask(), before);       // unchanged, and taller than the window
        QVERIFY(before.boundingRect().height() > w->height());

        w->resize(275, 116);
    }

    void cleanupTestCase() {
        foreign.reset();
        fx.host.reset();
        fx.ui.reset();
        fx.bridge.reset();
    }
};

int main(int argc, char** argv) {
    // Real QQuickWindows are created here. Offscreen so nothing appears on the
    // developer's desktop; QWindow::setMask stores and returns the region
    // whatever the platform does with it, which is the property under test.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    TstWindowShape tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_windowshape.moc"
