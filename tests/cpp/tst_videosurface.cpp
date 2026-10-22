#include <QtTest>
#include <QGuiApplication>
#include <QQuickView>
#include <QQmlComponent>
#include <QQuickItem>
#include <QImage>
#include <vector>
#include "VideoSurface.h"

// The surface draws what the source hands it, holds its frame when frozen,
// mixes the incoming picture over a fade, and does not shear a padded frame.
class FakeSource : public VideoFrameSource {
public:
    VideoView v;
    VideoView videoView() override { return v; }
};

static std::shared_ptr<const VideoPixels> solid(int w, int h, QColor c, int pad = 0) {
    const int stride = (w + pad) * 4;
    auto buf = std::make_shared<std::vector<unsigned char>>(std::size_t(stride) * h, 0);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            unsigned char* p = buf->data() + y * stride + x * 4;
            p[0] = c.red(); p[1] = c.green(); p[2] = c.blue(); p[3] = 255;
        }
    auto px = std::make_shared<VideoPixels>();
    px->width = w; px->height = h; px->keepAlive = buf;
    px->planes[0] = {buf->data(), w, h, stride};
    return px;
}

// A planar frame as a renderer without planes sees it: the twin carries the colour.
static std::shared_ptr<VideoPixels> planarWithTwin(int w, int h, QColor c) {
    static unsigned char bytes[64 * 64 * 2];
    auto px = std::make_shared<VideoPixels>();
    px->format = VideoFormat::NV12; px->width = w; px->height = h; px->planeCount = 2;
    px->planes[0] = {bytes, w, h, w};
    px->planes[1] = {bytes, (w + 1) / 2, (h + 1) / 2, w};
    px->makeRgba = [w, h, c] { return solid(w, h, c); };
    return px;
}

class TstVideoSurface : public QObject {
    Q_OBJECT
    FakeSource src_;
    QQuickView* view_ = nullptr;
    QQuickItem* surf_ = nullptr;
    QColor clear_;   // the window's clear colour, where no frame is drawn

    QColor pixelAt(int x, int y) { return view_->grabWindow().pixelColor(x, y); }

private slots:
    void initTestCase() {
        qmlRegisterType<VideoSurface>("Melo", 1, 0, "VideoSurface");
        VideoSurface::setSource(&src_);
        view_ = new QQuickView;
        view_->setResizeMode(QQuickView::SizeRootObjectToView);
        QQmlComponent comp(view_->engine());
        comp.setData("import QtQuick\nimport Melo 1.0\n"
                     "Item { VideoSurface { objectName: \"s\"; anchors.fill: parent; running: true } }",
                     QUrl());
        QVERIFY2(comp.isReady(), qPrintable(comp.errorString()));
        auto* rootItem = qobject_cast<QQuickItem*>(comp.create());
        QVERIFY(rootItem);
        rootItem->setParentItem(view_->contentItem());
        view_->resize(64, 64);
        rootItem->setSize(QSizeF(64, 64));
        view_->show();
        QVERIFY(QTest::qWaitForWindowExposed(view_));
        surf_ = rootItem->findChild<QQuickItem*>("s");
        QVERIFY(surf_);
        clear_ = pixelAt(32, 32);
    }
    void drawsTheMainFrame() {
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        QCOMPARE(surf_->property("hasFrame").toBool(), true);
    }
    void mixesTheIncomingFrameByTheFade() {
        src_.v = {solid(8, 8, Qt::black), solid(8, 8, Qt::white), 0.5, QString()};
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(pixelAt(32, 32).red() - 128) < 10, 2000);
        src_.v = {solid(8, 8, Qt::black), solid(8, 8, Qt::white), 1.0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::white), 2000);
    }
    void holdsTheLastFrameWhileFrozen() {
        src_.v = {solid(8, 8, Qt::blue), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::blue), 2000);
        surf_->setProperty("frozen", true);
        src_.v = {solid(8, 8, Qt::green), nullptr, 0, QString()};
        QTest::qWait(150);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::blue));
        surf_->setProperty("frozen", false);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::green), 2000);
    }
    void aPaddedStrideIsNotSheared() {
        // left half red, right half blue, with 5 px of padding per row
        auto px = solid(8, 8, Qt::red, 5);
        auto buf = std::static_pointer_cast<std::vector<unsigned char>>(px->keepAlive);
        for (int y = 0; y < 8; ++y)
            for (int x = 4; x < 8; ++x) {
                unsigned char* p = buf->data() + y * px->planes[0].stride + x * 4;
                p[0] = 0; p[2] = 255;
            }
        src_.v = {px, nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(8, 32), QColor(Qt::red), 2000);
        QCOMPARE(pixelAt(56, 32), QColor(Qt::blue));
        QCOMPARE(pixelAt(8, 60), QColor(Qt::red));     // bottom row still starts red: no shear
    }
    void noFrameMeansNothingDrawn() {
        surf_->setProperty("running", false);
        src_.v = {};
        surf_->setProperty("running", true);
        QTRY_COMPARE_WITH_TIMEOUT(surf_->property("hasFrame").toBool(), false, 2000);
        QTest::qWait(100);
        QCOMPARE(surf_->property("hasFrame").toBool(), false);
    }
    void aFrozenSurfaceStillCoversAResize() {
        src_.v = {solid(8, 8, Qt::magenta), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::magenta), 2000);
        surf_->setProperty("frozen", true);
        view_->resize(96, 96);
        surf_->parentItem()->setSize(QSizeF(96, 96));
        QTest::qWait(150);
        QCOMPARE(pixelAt(90, 90), QColor(Qt::magenta));
        surf_->setProperty("frozen", false);
        QTest::qWait(150);
        QCOMPARE(pixelAt(90, 90), QColor(Qt::magenta));
    }
    void doesNotRepaintWhenNothingChanged() {
        surf_->setProperty("running", true);
        src_.v = {solid(8, 8, Qt::cyan), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::cyan), 2000);
        const int before = VideoSurface::paintCount;
        QTest::qWait(300);
        QVERIFY2(VideoSurface::paintCount - before <= 2,
                 qPrintable(QString::number(VideoSurface::paintCount - before)));
    }
    // a 16x8 frame in the 64x64 item
    void fitLetterboxesAWideFrame() {
        view_->resize(64, 64);
        surf_->parentItem()->setSize(QSizeF(64, 64));
        surf_->setProperty("fit", "fit");
        src_.v = {solid(16, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);   // the band across the middle
        QCOMPARE(pixelAt(32, 4), clear_);                                   // bar above
        QCOMPARE(pixelAt(32, 60), clear_);                                  // bar below
    }
    void stretchFillsTheWholeItem() {
        surf_->setProperty("fit", "stretch");
        src_.v = {solid(16, 8, Qt::blue), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::blue), 2000);
        QCOMPARE(pixelAt(32, 4), QColor(Qt::blue));
        QCOMPARE(pixelAt(32, 60), QColor(Qt::blue));
        surf_->setProperty("fit", "fill");
    }
    // the 64x32 fit band zooms about the centre: by 1.5 at 0.5 (y 8..56), by 2 at 1
    void fillMixZoomsFitTowardFill() {
        surf_->setProperty("fit", "fit");
        surf_->setProperty("fillMix", 0.0);
        src_.v = {solid(16, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        QCOMPARE(pixelAt(32, 4), clear_);
        QCOMPARE(surf_->property("contentRect").toRectF(), QRectF(0, 16, 64, 32));
        surf_->setProperty("fillMix", 0.5);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 10), QColor(Qt::red), 2000);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::red));
        QCOMPARE(pixelAt(32, 4), clear_);
        QTRY_COMPARE_WITH_TIMEOUT(surf_->property("contentRect").toRectF(), QRectF(0, 8, 64, 48), 2000);
        surf_->setProperty("fillMix", 1.0);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 4), QColor(Qt::red), 2000);
        surf_->setProperty("fillMix", 0.0);
        surf_->setProperty("fit", "fill");
    }
    // On the software scene graph a planar frame is drawn through its RGBA twin.
    void aPlanarFrameDrawsItsTwinWithoutPlanes() {
        surf_->setProperty("running", true);
        src_.v = {planarWithTwin(8, 8, Qt::darkGreen), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::darkGreen), 2000);
    }
    // A planar frame with no twin cannot be drawn here: the previous picture stays.
    void aPlanarFrameWithoutATwinKeepsThePicture() {
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        auto px = planarWithTwin(8, 8, Qt::blue);
        px->makeRgba = nullptr;
        src_.v = {px, nullptr, 0, QString()};
        QTest::qWait(150);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::red));
    }
    // The kept picture keeps its own size: a wide frame it could not draw does not letterbox it.
    void aKeptPictureKeepsItsPlacement() {
        surf_->setProperty("fit", "fit");
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 4), QColor(Qt::red), 2000);
        auto px = planarWithTwin(16, 8, Qt::blue);
        px->makeRgba = nullptr;
        src_.v = {px, nullptr, 0, QString()};
        QTest::qWait(150);
        surf_->update();
        QTest::qWait(100);
        QCOMPARE(pixelAt(32, 4), QColor(Qt::red));
        QCOMPARE(surf_->property("contentRect").toRectF(), QRectF(0, 0, 64, 64));
        surf_->setProperty("fit", "fill");
    }
    // A twin that cannot be made is tried once per frame, not on every paint.
    void aFailedTwinIsTriedOnce() {
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        auto px = planarWithTwin(8, 8, Qt::blue);
        auto tries = std::make_shared<int>(0);
        px->makeRgba = [tries] { ++*tries; return std::shared_ptr<const VideoPixels>(); };
        src_.v = {px, nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(*tries, 1, 2000);
        for (int i = 0; i < 3; ++i) { surf_->update(); QTest::qWait(50); }
        QCOMPARE(*tries, 1);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::red));
    }
    // A frame it cannot draw is asked for once, not repainted on every tick.
    void aFrameItCannotDrawIsNotRepainted() {
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QString()};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        auto px = planarWithTwin(8, 8, Qt::blue);
        px->makeRgba = nullptr;
        src_.v = {px, nullptr, 0, QString()};
        QTest::qWait(100);
        const int before = VideoSurface::paintCount;
        QTest::qWait(80);   // five ticks
        QVERIFY2(VideoSurface::paintCount - before <= 1,
                 qPrintable(QString::number(VideoSurface::paintCount - before)));
        QCOMPARE(pixelAt(32, 32), QColor(Qt::red));
    }
    void keepsTheLastPictureUntilHidden() {
        surf_->setProperty("running", true);
        src_.v = {solid(8, 8, Qt::red), nullptr, 0, QStringLiteral("t")};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::red), 2000);
        src_.v = {};                                   // the source has nothing this tick
        QTest::qWait(150);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::red));    // still the picture, not the clear colour
        QCOMPARE(surf_->property("hasFrame").toBool(), true);
        surf_->setProperty("running", false);
        QTRY_COMPARE_WITH_TIMEOUT(surf_->property("hasFrame").toBool(), false, 2000);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), clear_, 2000);
    }
    // an empty view for another track drops the held picture
    void anotherTracksEmptyViewDropsThePicture() {
        surf_->setProperty("running", true);
        src_.v = {solid(8, 8, Qt::green), nullptr, 0, QStringLiteral("a")};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::green), 2000);
        src_.v = {nullptr, nullptr, 0, QStringLiteral("b")};
        QTRY_COMPARE_WITH_TIMEOUT(surf_->property("hasFrame").toBool(), false, 2000);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), clear_, 2000);
    }
    // a frozen surface still never shows another track's picture: it takes the new one
    void aFrozenSurfaceTakesAnotherTracksPicture() {
        surf_->setProperty("running", true);
        surf_->setProperty("frozen", false);
        src_.v = {solid(8, 8, Qt::yellow), nullptr, 0, QStringLiteral("a")};
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::yellow), 2000);
        surf_->setProperty("frozen", true);
        src_.v = {solid(8, 8, Qt::darkBlue), nullptr, 0, QStringLiteral("b")};
        QTest::qWait(150);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::yellow));                          // no polling while frozen
        VideoSurface::notifyTrackChange();
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::darkBlue), 2000);
        src_.v = {solid(8, 8, Qt::darkRed), nullptr, 0, QStringLiteral("b")};   // same track: still held
        VideoSurface::notifyTrackChange();
        QTest::qWait(150);
        QCOMPARE(pixelAt(32, 32), QColor(Qt::darkBlue));
        surf_->setProperty("frozen", false);
        QTRY_COMPARE_WITH_TIMEOUT(pixelAt(32, 32), QColor(Qt::darkRed), 2000);
    }
    // the frame at its own size, from a planar frame's twin, named after the
    // track and its place; a slash in the title names no folder
    void snapshotSavesTheFrameAtItsOwnSize() {
        QTemporaryDir home;
        QVERIFY(home.isValid());
        QFile dirs(home.filePath("user-dirs.dirs"));
        QVERIFY(dirs.open(QIODevice::WriteOnly));
        dirs.write(QStringLiteral("XDG_PICTURES_DIR=\"%1/pics\"\n").arg(home.path()).toUtf8());
        dirs.close();
        qputenv("XDG_CONFIG_HOME", home.path().toUtf8());
        auto px = planarWithTwin(40, 30, Qt::green);
        px->pts = 83.4;
        src_.v = {px, nullptr, 0, QString()};
        QString path;
        QMetaObject::invokeMethod(surf_, "snapshot", Q_RETURN_ARG(QString, path), Q_ARG(QString, "AC/DC: Live"));
        QCOMPARE(path, home.filePath("pics/melo/AC DC Live 1m23s.png"));
        const QImage img(path);
        QCOMPARE(img.size(), QSize(40, 30));
        QCOMPARE(img.pixelColor(20, 15), QColor(Qt::green));
        QString again;
        QMetaObject::invokeMethod(surf_, "snapshot", Q_RETURN_ARG(QString, again), Q_ARG(QString, "AC/DC: Live"));
        QCOMPARE(again, home.filePath("pics/melo/AC DC Live 1m23s (2).png"));
        src_.v = {};
        QMetaObject::invokeMethod(surf_, "snapshot", Q_RETURN_ARG(QString, again), Q_ARG(QString, "x"));
        QCOMPARE(again, QString());
        qunsetenv("XDG_CONFIG_HOME");
    }
};

QTEST_MAIN(TstVideoSurface)
#include "tst_videosurface.moc"
