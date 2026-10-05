#include <QtTest>
#include <QGuiApplication>
#include <QQuickView>
#include <QQmlComponent>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <vector>
#include "VideoSurface.h"

// The planar material on a real GPU: NV12 and I420 with known YUV come out as
// the RGB the colour matrix says; padded strides and odd sizes do not shear; a
// size change shows the new picture; the crossfade and item opacity blend.
// Not offscreen: the software scene graph has no materials, so this skips there.
class FakeSource : public VideoFrameSource {
public:
    VideoView v;
    VideoView videoView() override { return v; }
};

struct Yuv { int y, u, v; };

// Left half `left`, right half `right` (top and bottom when `vertical`). `pad` is
// extra bytes on each luma row (chroma rows get pad/2 rounded up to even).
// BT.709, limited unless `full`.
static std::shared_ptr<VideoPixels> planar(VideoFormat fmt, int w, int h, Yuv left, Yuv right,
                                           int pad = 0, bool full = false, bool vertical = false) {
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    const int cpad = (pad + 3) / 4 * 2;
    const int ys = w + pad, cs = (fmt == VideoFormat::NV12 ? cw * 2 : cw) + cpad;
    auto buf = std::make_shared<std::vector<unsigned char>>(std::size_t(ys) * h + std::size_t(cs) * ch * 2, 0);
    unsigned char* Y = buf->data();
    unsigned char* C1 = Y + std::size_t(ys) * h;
    unsigned char* C2 = C1 + std::size_t(cs) * ch;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) Y[y * ys + x] = (unsigned char)(((vertical ? y < h / 2 : x < w / 2) ? left : right).y);
    for (int y = 0; y < ch; ++y)
        for (int x = 0; x < cw; ++x) {
            const Yuv& s = (vertical ? y < ch / 2 : x < cw / 2) ? left : right;
            if (fmt == VideoFormat::NV12) { C1[y * cs + 2 * x] = (unsigned char)s.u; C1[y * cs + 2 * x + 1] = (unsigned char)s.v; }
            else { C1[y * cs + x] = (unsigned char)s.u; C2[y * cs + x] = (unsigned char)s.v; }
        }
    auto px = std::make_shared<VideoPixels>();
    px->format = fmt; px->width = w; px->height = h; px->keepAlive = buf;
    px->color = {VideoMatrix::BT709, full};
    px->planes[0] = {Y, w, h, ys};
    px->planes[1] = {C1, cw, ch, cs};
    if (fmt == VideoFormat::NV12) px->planeCount = 2;
    else { px->planeCount = 3; px->planes[2] = {C2, cw, ch, cs}; }
    return px;
}

static std::shared_ptr<const VideoPixels> rgba(int w, int h, QColor c) {
    auto buf = std::make_shared<std::vector<unsigned char>>(std::size_t(w) * h * 4, 255);
    for (std::size_t i = 0; i < buf->size(); i += 4) {
        (*buf)[i] = (unsigned char)c.red(); (*buf)[i + 1] = (unsigned char)c.green(); (*buf)[i + 2] = (unsigned char)c.blue();
    }
    auto px = std::make_shared<VideoPixels>();
    px->width = w; px->height = h; px->keepAlive = buf;
    px->planes[0] = {buf->data(), w, h, w * 4};
    return px;
}

// BT.709 limited: grey 128 → 130; white 235 → 255
static const Yuv kGrey{128, 128, 128}, kWhite{235, 128, 128}, kRed{63, 102, 240}, kBlue{32, 240, 118};

class TstVideoPlanes : public QObject {
    Q_OBJECT
    FakeSource src_;
    QQuickView* view_ = nullptr;
    QQuickItem* surf_ = nullptr;

    // fractions of the window, so the device pixel ratio does not matter
    QColor at(double fx, double fy) {
        const QImage shot = view_->grabWindow();
        return shot.pixelColor(int(shot.width() * fx), int(shot.height() * fy));
    }
    static bool close(QColor got, int r, int g, int b, int tol) {
        return qAbs(got.red() - r) <= tol && qAbs(got.green() - g) <= tol && qAbs(got.blue() - b) <= tol;
    }
    void expect(double fx, double fy, int r, int g, int b, int tol = 3) {
        QTRY_VERIFY_WITH_TIMEOUT(close(at(fx, fy), r, g, b, tol), 2000);
        const QColor got = at(fx, fy);
        QVERIFY2(close(got, r, g, b, tol), qPrintable(QStringLiteral("wanted rgb(%1,%2,%3) got rgb(%4,%5,%6)")
            .arg(r).arg(g).arg(b).arg(got.red()).arg(got.green()).arg(got.blue())));
    }
    void show(std::shared_ptr<const VideoPixels> main, std::shared_ptr<const VideoPixels> incoming = nullptr, double mix = 0) {
        src_.v = {std::move(main), std::move(incoming), mix, QString()};
    }

private slots:
    void initTestCase() {
        qmlRegisterType<VideoSurface>("Melo", 1, 0, "VideoSurface");
        VideoSurface::setSource(&src_);
        view_ = new QQuickView;
        view_->setColor(Qt::black);
        view_->setResizeMode(QQuickView::SizeRootObjectToView);
        QQmlComponent comp(view_->engine());
        comp.setData("import QtQuick\nimport Melo 1.0\n"
                     "Item { VideoSurface { objectName: \"s\"; anchors.fill: parent; running: true; fit: \"stretch\" } }",
                     QUrl());
        QVERIFY2(comp.isReady(), qPrintable(comp.errorString()));
        auto* rootItem = qobject_cast<QQuickItem*>(comp.create());
        QVERIFY(rootItem);
        rootItem->setParentItem(view_->contentItem());
        view_->resize(64, 64);
        rootItem->setSize(QSizeF(64, 64));
        view_->show();
        if (!QTest::qWaitForWindowExposed(view_))
            QSKIP("the window system did not expose a window; run on an unlocked desktop");
        if (view_->rendererInterface()->graphicsApi() == QSGRendererInterface::Software)
            QSKIP("software scene graph: no materials to test here");
        surf_ = rootItem->findChild<QQuickItem*>("s");
        QVERIFY(surf_);
    }
    void nv12GreyIsLimitedRangeGrey() {
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey));
        expect(0.5, 0.5, 130, 130, 130);
    }
    void nv12RedAndBlueHalves() {
        show(planar(VideoFormat::NV12, 8, 8, kRed, kBlue));
        expect(0.125, 0.5, 255, 0, 0);
        expect(0.875, 0.5, 0, 0, 255);
    }
    void i420RedAndBlueHalves() {
        show(planar(VideoFormat::I420, 8, 8, kRed, kBlue));
        expect(0.125, 0.5, 255, 0, 0);
        expect(0.875, 0.5, 0, 0, 255);
    }
    void fullRangeGreyIsGrey() {
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey, 0, true));
        expect(0.5, 0.5, 128, 128, 128);
    }
    // 161x91 with 15 bytes of luma padding a row: left stays red down to the bottom row
    void paddedOddFramesAreNotSheared() {
        show(planar(VideoFormat::NV12, 161, 91, kRed, kBlue, 15));
        expect(0.125, 0.5, 255, 0, 0);
        expect(0.875, 0.5, 0, 0, 255);
        expect(0.125, 0.94, 255, 0, 0);
        show(planar(VideoFormat::I420, 161, 91, kRed, kBlue, 15));
        expect(0.125, 0.5, 255, 0, 0);
        expect(0.875, 0.5, 0, 0, 255);
        expect(0.125, 0.94, 255, 0, 0);
    }
    // 321x241: odd luma and chroma rows, unpadded (stride 321) and padded (328, chroma 326 / 165)
    void oddWidthFramesKeepTheirRightEdge() {
        for (VideoFormat f : {VideoFormat::NV12, VideoFormat::I420})
            for (int pad : {0, 7}) {
                show(planar(f, 321, 241, kRed, kBlue, pad));
                expect(0.02, 0.5, 255, 0, 0);
                expect(0.98, 0.5, 0, 0, 255);
                expect(0.40, 0.98, 255, 0, 0);
                expect(0.60, 0.98, 0, 0, 255);
                expect(0.98, 0.98, 0, 0, 255);
                expect(0.98, 0.02, 0, 0, 255);
            }
    }
    // red over blue: a flipped upload puts blue on top
    void theTopRowIsTheTop() {
        show(planar(VideoFormat::NV12, 8, 8, kRed, kBlue, 0, false, true));
        expect(0.5, 0.06, 255, 0, 0);
        expect(0.5, 0.94, 0, 0, 255);
        show(planar(VideoFormat::I420, 8, 8, kRed, kBlue, 0, false, true));
        expect(0.5, 0.06, 255, 0, 0);
        expect(0.5, 0.94, 0, 0, 255);
    }
    void aSizeChangeShowsTheNewPicture() {
        show(planar(VideoFormat::NV12, 8, 8, kRed, kRed));
        expect(0.5, 0.5, 255, 0, 0);
        show(planar(VideoFormat::NV12, 16, 8, kBlue, kBlue));
        expect(0.5, 0.5, 0, 0, 255);
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey));
        expect(0.5, 0.5, 130, 130, 130);
    }
    void theCrossfadeBlendsNv12UnderI420() {
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey), planar(VideoFormat::I420, 8, 8, kWhite, kWhite), 0.5);
        expect(0.5, 0.5, 192, 192, 192, 6);
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey), planar(VideoFormat::I420, 8, 8, kWhite, kWhite), 1.0);
        expect(0.5, 0.5, 255, 255, 255);
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey));
        expect(0.5, 0.5, 130, 130, 130);
    }
    // the main picture turns from a texture node into planes mid-fade and stays under it
    void anRgbaMainTurnsPlanarUnderTheFade() {
        show(rgba(8, 8, Qt::red));
        expect(0.5, 0.5, 255, 0, 0);
        const auto in = planar(VideoFormat::I420, 8, 8, kWhite, kWhite);
        show(rgba(8, 8, Qt::black), in, 0.5);
        expect(0.5, 0.5, 128, 128, 128, 6);
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey), in, 0.5);
        expect(0.5, 0.5, 192, 192, 192, 6);
        show(planar(VideoFormat::NV12, 8, 8, kGrey, kGrey));
        expect(0.5, 0.5, 130, 130, 130);
    }
    void itemOpacityFadesThePicture() {
        show(planar(VideoFormat::I420, 8, 8, kWhite, kWhite));
        expect(0.5, 0.5, 255, 255, 255);
        surf_->setProperty("opacity", 0.5);
        expect(0.5, 0.5, 128, 128, 128, 6);
        surf_->setProperty("opacity", 1.0);
        expect(0.5, 0.5, 255, 255, 255);
    }
};

QTEST_MAIN(TstVideoPlanes)
#include "tst_videoplanes.moc"
