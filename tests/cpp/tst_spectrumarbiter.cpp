// Who switches the FFT on when writers disagree. A ui plugin's mini mode needs
// the FFT whatever melo's background is, so holds are keyed by owner. The key
// row is the third in arbitratesBetweenIndependentOwners(): the background
// releases while the plugin host holds, and analysis must continue; a
// last-writer-wins bool fails only there. The refcount rows cover
// PluginWindowHost restating `true` on every show/hide and making three
// unpaired releases (build(), mini exit, destructor).
#include <QtTest>
#include <QCoreApplication>
#include <QStringList>
#include <algorithm>
#include <cmath>
#include <vector>

#include "SpectrumSource.h"

namespace {
constexpr const char* kBg     = "background";
constexpr const char* kPlugin = "plugin-windows";

// One analyse() tick is 16ms. Wait for several, so a machine under load does
// not turn "the FFT ran" into a flake.
constexpr int kTickWaitMs = 120;

// A DC block is enough: wave() is the time-domain observable, and what is
// being measured is whether the samples reached the ring AT ALL, not what the
// FFT made of them.
void feedBlock(float level, int monoSamples) {
    std::vector<float> buf(static_cast<std::size_t>(monoSamples) * 2, level);
    SpectrumSource::feed(buf.data(), buf.size());
}

float peakWave(const SpectrumSource& s) {
    float peak = 0.0f;
    for (const QVariant& v : s.wave()) peak = std::max(peak, std::abs(v.toFloat()));
    return peak;
}

// `ring_` is static and never reset, so zero it before each audio row or the
// rows depend on declaration order. feed() is gated on the arbiter, so this
// takes a hold to do it.
void silenceRing(SpectrumSource& s) {
    const QString k = QStringLiteral("test-flush");
    s.request(k, true);
    feedBlock(0.0f, 4096);          // 4x the window: every slot overwritten
    s.request(k, false);
}
}  // namespace

class TestSpectrumArbiter : public QObject {
    Q_OBJECT
private slots:

    // ---------------------------------------------------------------- ordering
    // The four states, in the order that separates an arbiter from a bool.
    void arbitratesBetweenIndependentOwners() {
        SpectrumSource s;
        QVERIFY2(!s.running(), "a fresh source must not be running");

        // 1. background on, plugin off.
        s.request(kBg, true);
        QVERIFY(s.running());
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kBg)});

        // 2. both on. The second owner must not be able to disturb the first.
        s.request(kPlugin, true);
        QVERIFY(s.running());
        QCOMPARE(s.owners(), (QStringList{QString::fromLatin1(kBg),
                                          QString::fromLatin1(kPlugin)}));

        // 3. The row that matters. The user switches melo's background away
        //    from a vis type while a plugin analyser is on screen. A
        //    last-writer-wins bool would turn the analyser dark here; the FFT
        //    must keep running for the owner that remains.
        s.request(kBg, false);
        QVERIFY2(s.running(), "an owner that stopped wanting the FFT switched it "
                              "off under an owner that still does");
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kPlugin)});

        // 4. and only when NOBODY wants it does it stop.
        s.request(kPlugin, false);
        QVERIFY(!s.running());
        QVERIFY(s.owners().isEmpty());
    }

    // The mirror image, so the pass in row 3 above cannot be an artefact of
    // which owner was released: drop the plugin first and melo's own
    // background must keep the analysis it is rendering from.
    void releasingThePluginLeavesTheBackgroundRunning() {
        SpectrumSource s;
        s.request(kBg, true);
        s.request(kPlugin, true);
        s.request(kPlugin, false);
        QVERIFY(s.running());
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kBg)});
        s.request(kBg, false);
        QVERIFY(!s.running());
    }

    // ------------------------------------------------------- refcount failures
    // syncSpectrum restates `true` on every show/hide, so three shown windows
    // are three requests under one key; a refcount would stay at 2 after the
    // single release and pin 60fps FFTs on for the process.
    void repeatedRequestsFromOneOwnerReleaseInOneCall() {
        SpectrumSource s;
        s.request(kBg, true);
        s.request(kBg, true);
        s.request(kBg, true);
        QCOMPARE(s.owners().size(), 1);
        s.request(kBg, false);
        QVERIFY2(!s.running(), "one owner's release did not stop the FFT — the "
                               "hold is being counted rather than keyed");
    }

    // The other direction. PluginWindowHost releases on leaving mini mode and
    // again in its destructor, so a double release is a NORMAL path here, not
    // a caller bug. It must not reach under a live owner.
    void aDoubleReleaseCannotStopTheFftUnderAnotherOwner() {
        SpectrumSource s;
        s.request(kBg, true);
        s.request(kPlugin, true);
        s.request(kPlugin, false);
        s.request(kPlugin, false);
        s.request(kPlugin, false);
        QVERIFY2(s.running(), "a repeated release went through the remaining owner");
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kBg)});
    }

    // Releasing a key nobody ever took is the same non-event.
    void releasingAnUnknownOwnerChangesNothing() {
        SpectrumSource s;
        s.request(kBg, true);
        s.request(QStringLiteral("never-registered"), false);
        QVERIFY(s.running());
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kBg)});
    }

    // An unnamed owner is refused on BOTH sides. It could not be released by
    // name, so it must not be able to take a hold either — and it must not be
    // able to release someone else's.
    void anUnnamedOwnerCanNeitherHoldNorRelease() {
        SpectrumSource s;
        s.request(QString(), true);
        QVERIFY2(!s.running(), "an owner with no key took a hold nothing can clear");
        QVERIFY(s.owners().isEmpty());

        s.request(kBg, true);
        s.request(QString(), false);
        QVERIFY2(s.running(), "an empty key released a real owner's hold");
        QCOMPARE(s.owners(), QStringList{QString::fromLatin1(kBg)});
    }

    // --------------------------------------------------------- the audio path
    // feed() early-returns on the arbiter state, so a timer-only implementation
    // would pass the rows above and paint a flat line. The "dropped" half runs
    // first against a zeroed ring, since the ring is shared by both halves.
    void samplesFedWithNoOwnerNeverReachTheRing() {
        SpectrumSource s;
        silenceRing(s);
        QVERIFY(!s.running());
        feedBlock(0.8f, 4096);                  // 4x the window, unowned
        s.request(kBg, true);                   // now start the analysis
        QTest::qWait(kTickWaitMs);
        const float peak = peakWave(s);
        QVERIFY2(peak < 0.01f,
                 qPrintable(QStringLiteral("audio fed while nobody wanted the FFT "
                                           "reached the ring (peak %1)").arg(peak)));
        s.request(kBg, false);
    }

    // `active_` is static, so a source destroyed while held would leave the
    // GStreamer thread pushing PCM with nothing to analyse it.
    void aSourceDestroyedHoldingAnOwnerStopsTheAudioPath() {
        { SpectrumSource flush; silenceRing(flush); }
        { SpectrumSource dying; dying.request(kBg, true); QVERIFY(dying.running()); }
        feedBlock(0.8f, 4096);                  // nobody is alive to want this

        SpectrumSource s;
        s.request(kBg, true);
        QTest::qWait(kTickWaitMs);
        const float peak = peakWave(s);
        QVERIFY2(peak < 0.01f,
                 qPrintable(QStringLiteral("a destroyed source left the audio path "
                                           "publishing (peak %1)").arg(peak)));
        s.request(kBg, false);
    }

    void samplesFedWhileAnOwnerHoldsItDoReachTheRing() {
        SpectrumSource s;
        silenceRing(s);                         // start from a known-silent ring
        s.request(kPlugin, true);               // the PLUGIN host's key alone
        feedBlock(0.8f, 4096);
        QTest::qWait(kTickWaitMs);
        const float peak = peakWave(s);
        QVERIFY2(peak > 0.5f,
                 qPrintable(QStringLiteral("the plugin host's hold did not deliver "
                                           "audio to the analysis (peak %1)").arg(peak)));
        s.request(kPlugin, false);
        QVERIFY(!s.running());
    }
};

QTEST_GUILESS_MAIN(TestSpectrumArbiter)
#include "tst_spectrumarbiter.moc"
