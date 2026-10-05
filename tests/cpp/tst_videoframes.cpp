#include <QtTest>
#include "VideoFrameRing.h"
#include "VideoFrame.h"
#include "VideoCodecs.h"
#include "VideoColorMatrix.h"
#include <array>
#include <cmath>
#include <set>
#include <string>

// The surface asks for "the newest frame at or under the audio position"; this
// is everything that rule must do, without a decoder.
class TstVideoFrames : public QObject {
    Q_OBJECT
    static VideoFrame f(double pts, uint64_t gen = 0) { return VideoFrame{pts, gen, nullptr}; }
    // Compares a row-major matrix with a published YUV→RGB table, entry by entry, within tol.
    static void rows(const std::array<float, 16>& got, std::initializer_list<float> want, double tol) {
        QCOMPARE(want.size(), size_t(16));
        int i = 0;
        for (float w : want) {
            QVERIFY2(std::abs(got[i] - w) <= tol,
                     qPrintable(QStringLiteral("[%1] wanted %2 got %3").arg(i).arg(w).arg(got[i])));
            ++i;
        }
    }

private slots:
    void newestAtOrUnderPositionWins() {
        VideoFrameRing r;
        r.push(f(0.00)); r.push(f(0.04)); r.push(f(0.08)); r.push(f(0.12));
        const auto got = r.take(0.09);
        QVERIFY(got);
        QCOMPARE(got->pts, 0.08);
    }
    void leadLetsTheNextFrameShowALittleEarly() {
        VideoFrameRing r;
        r.push(f(0.00)); r.push(f(0.04));
        QCOMPARE(r.take(0.025, 0.02)->pts, 0.04);
        VideoFrameRing s;
        s.push(f(0.00)); s.push(f(0.04));
        QCOMPARE(s.take(0.015, 0.02)->pts, 0.00);
    }
    void olderFramesAreReleasedNewerAreKept() {
        VideoFrameRing r;
        r.push(f(0.00)); r.push(f(0.04)); r.push(f(0.08)); r.push(f(0.12));
        r.take(0.09);
        QCOMPARE(r.size(), std::size_t(1));          // only 0.12 left
        QCOMPARE(r.take(0.20)->pts, 0.12);
    }
    void nothingQualifiesMeansNoFrameAndNothingLost() {
        VideoFrameRing r;
        r.push(f(0.50)); r.push(f(0.54));
        QVERIFY(!r.take(0.10));
        QCOMPARE(r.size(), std::size_t(2));
    }
    void aSeekDropsEveryOlderGeneration() {
        VideoFrameRing r;
        r.push(f(0.00, 0)); r.push(f(0.04, 0));
        r.bumpGeneration();
        QCOMPARE(r.generation(), uint64_t(1));
        r.push(f(0.02, 0));                            // decoded before the flush, pushed after
        r.push(f(30.00, 1));
        QVERIFY(!r.take(0.10));                        // the stale ones never show
        QCOMPARE(r.take(30.0)->pts, 30.0);
    }
    void aFullRingDropsItsOldest() {
        VideoFrameRing r(3);
        r.push(f(0.0)); r.push(f(0.1)); r.push(f(0.2)); r.push(f(0.3));
        QCOMPARE(r.size(), std::size_t(3));
        QVERIFY(!r.take(0.05));                        // 0.0 is gone; 0.1 is past 0.05+lead
        QCOMPARE(r.take(0.10)->pts, 0.1);
    }
    void clearEmptiesIt() {
        VideoFrameRing r;
        r.push(f(0.0));
        r.clear();
        QCOMPARE(r.size(), std::size_t(0));
        QVERIFY(!r.take(1.0));
    }
    void newestPtsIsTheLastPushed() {
        VideoFrameRing r;
        QVERIFY(!r.newestPts());
        r.push(f(0.0)); r.push(f(0.04));
        QCOMPARE(*r.newestPts(), 0.04);
    }

    // rgbaOf: an RGBA frame is its own RGBA; a planar frame's twin is made once and kept.
    void rgbaOfAnRgbaFrameIsTheFrame() {
        std::shared_ptr<const VideoPixels> p = std::make_shared<VideoPixels>();
        QVERIFY(rgbaOf(p) == p);
    }
    void rgbaOfAPlanarFrameIsMadeOnceAndKept() {
        auto p = std::make_shared<VideoPixels>();
        p->format = VideoFormat::NV12; p->width = 4; p->height = 2; p->planeCount = 2;
        int made = 0;
        p->makeRgba = [&made] {
            ++made;
            auto t = std::make_shared<VideoPixels>();
            t->width = 4; t->height = 2;
            return t;
        };
        const std::shared_ptr<const VideoPixels> c = p;
        const auto a = rgbaOf(c), b = rgbaOf(c);
        QVERIFY(a);
        QVERIFY(a == b);
        QCOMPARE(made, 1);
        QVERIFY(a->format == VideoFormat::RGBA);
        QCOMPARE(a->width, 4);
    }
    void rgbaOfAPlanarFrameWithoutAMakerIsNull() {
        auto p = std::make_shared<VideoPixels>();
        p->format = VideoFormat::I420;
        QVERIFY(!rgbaOf(p));
        QVERIFY(!rgbaOf(nullptr));
    }
    // Decoder probe: hardware first, then AV1, VP9, H.264; names only what decodes.
    void codecPreferenceFollowsTheInstalledDecoders() {
        const std::set<std::string> fedora = {"vp9dec", "dav1ddec", "av1dec"};
        const auto has = [&](const char* n) { return fedora.count(n) > 0; };
        QCOMPARE(videoCodecPreference(has), QStringList({"av1", "vp9"}));
        const std::set<std::string> va = {"vah264dec", "vp9dec", "avdec_h264"};
        const auto hasVa = [&](const char* n) { return va.count(n) > 0; };
        QCOMPARE(videoCodecPreference(hasVa), QStringList({"h264", "vp9"}));
        const auto none = [](const char*) { return false; };
        QCOMPARE(videoCodecPreference(none), QStringList());
    }
    void bt709LimitedMatchesQt() {
        rows(videoColorMatrix({VideoMatrix::BT709, false}),
             {1.1644f, 0.f, 1.7927f, -0.9729f,  1.1644f, -0.2132f, -0.5329f, 0.3015f,
              1.1644f, 2.1124f, 0.f, -1.1334f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
    void bt709FullMatchesQt() {
        rows(videoColorMatrix({VideoMatrix::BT709, true}),
             {1.f, 0.f, 1.5748f, -0.790488f,  1.f, -0.187324f, -0.468124f, 0.329010f,
              1.f, 1.855600f, 0.f, -0.931439f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
    void bt601LimitedMatchesStandard() {
        // The standard table; Qt's 601 offsets assume a 128/256 chroma centre
        rows(videoColorMatrix({VideoMatrix::BT601, false}),
             {1.1644f, 0.f, 1.5960f, -0.8742f,  1.1644f, -0.3918f, -0.8130f, 0.5317f,
              1.1644f, 2.0172f, 0.f, -1.0856f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
    void bt601FullMatchesStandard() {
        rows(videoColorMatrix({VideoMatrix::BT601, true}),
             {1.f, 0.f, 1.402f, -0.7037f,  1.f, -0.3441f, -0.7141f, 0.5312f,
              1.f, 1.772f, 0.f, -0.8895f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
    void bt2020FullMatchesStandard() {
        rows(videoColorMatrix({VideoMatrix::BT2020, true}),
             {1.f, 0.f, 1.4746f, -0.7402f,  1.f, -0.1646f, -0.5714f, 0.3694f,
              1.f, 1.8814f, 0.f, -0.9444f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
    void bt2020LimitedMatchesQt() {
        rows(videoColorMatrix({VideoMatrix::BT2020, false}),
             {1.1644f, 0.f, 1.6787f, -0.9157f,  1.1644f, -0.1874f, -0.6504f, 0.3475f,
              1.1644f, 2.1418f, 0.f, -1.1483f,  0.f, 0.f, 0.f, 1.f}, 0.002);
    }
};

QTEST_GUILESS_MAIN(TstVideoFrames)
#include "tst_videoframes.moc"
