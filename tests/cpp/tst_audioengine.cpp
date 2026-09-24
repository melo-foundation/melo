#include <QtTest>
#include <QElapsedTimer>
#include <QTemporaryDir>
#include <gst/gst.h>
#include <cmath>
#include <memory>
#include "AudioEngine.h"
#include "PcmQueue.h"
#include "PlayerState.h"

// AudioEngine builds a real GStreamer pipeline. MELO_FAKE_SINK swaps the audio
// sink for a fakesink, so the engine IS constructible headlessly and its EQ
// state is tested on the real object. Balance stays at the PlayerState seam —
// the state the engine and the UI both read.
class TestAudioEngine : public QObject {
    Q_OBJECT

    // Fresh engine per test: EQ state is sticky by design, so sharing one would
    // let an earlier case's curve decide a later case's assertions.
    std::unique_ptr<AudioEngine> makeEngine() {
        return std::make_unique<AudioEngine>(queue_);
    }
    PcmQueue queue_;
    std::unique_ptr<QTemporaryDir> tempDir_;

    QString makeSeekFixture() {
        tempDir_ = std::make_unique<QTemporaryDir>();
        if (!tempDir_->isValid()) return {};
        const QString path = tempDir_->filePath(QStringLiteral("seek.webm"));

        GError* error = nullptr;
        GstElement* writer = gst_parse_launch(
            "audiotestsrc num-buffers=500 wave=sine ! "
            "audio/x-raw,rate=48000,channels=2 ! opusenc ! webmmux ! "
            "filesink name=fixtureout", &error);
        if (!writer) {
            if (error) g_error_free(error);
            return {};
        }
        GstElement* out = gst_bin_get_by_name(GST_BIN(writer), "fixtureout");
        g_object_set(out, "location", path.toUtf8().constData(), nullptr);
        gst_object_unref(out);
        gst_element_set_state(writer, GST_STATE_PLAYING);
        GstBus* bus = gst_element_get_bus(writer);
        GstMessage* message = gst_bus_timed_pop_filtered(bus, 10 * GST_SECOND,
            (GstMessageType)(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        const bool ok = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
        if (message) gst_message_unref(message);
        gst_object_unref(bus);
        gst_element_set_state(writer, GST_STATE_NULL);
        gst_object_unref(writer);
        if (error) g_error_free(error);
        return ok ? path : QString();
    }

private slots:
    void initTestCase() {
        qputenv("MELO_FAKE_SINK", "1");   // no audio device in a unit test
        gst_init(nullptr, nullptr);
    }

    void seekCannotDeadlockTheMixerBranch() {
        const QString fixture = makeSeekFixture();
        QVERIFY2(!fixture.isEmpty(), "could not create the WebM/Opus seek fixture");
        auto eng = makeEngine();
        eng->loadTrack(fixture);
        QTRY_VERIFY_WITH_TIMEOUT(eng->duration() > 5.0, 5000);

        // A flushing seek can leave the decoder's multiqueue task blocked
        // inside audiomixer while the GUI thread waits for that same task to
        // pause. Repeated seeks against WebM/Opus exercise that demuxer,
        // decoder and multiqueue stack.
        for (int i = 0; i < 20; ++i) {
            QElapsedTimer elapsed;
            elapsed.start();
            eng->seekTo(0.25 + (i % 8));
            QVERIFY2(elapsed.elapsed() < 1000,
                     qPrintable(QStringLiteral("seek %1 blocked for %2 ms")
                                .arg(i).arg(elapsed.elapsed())));
            QTest::qWait(10);
        }
    }

    // Picking a track while paused, with crossfade on, must start the
    // pipeline. Marking the engine playing over a paused pipeline gives
    // silence with the play button lit, and play then does nothing.
    void crossfadeFromPauseStartsThePipeline() {
        const QString fixture = makeSeekFixture();
        QVERIFY2(!fixture.isEmpty(), "could not create the WebM/Opus fixture");
        auto eng = makeEngine();
        eng->loadTrack(fixture);
        QTRY_VERIFY_WITH_TIMEOUT(eng->duration() > 5.0, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(eng->pipelinePlaying(), 5000);
        eng->setPaused(true);
        QTRY_VERIFY_WITH_TIMEOUT(!eng->pipelinePlaying(), 5000);

        eng->crossfadeTo(fixture, 2.0);
        QVERIFY(!eng->paused());
        QTRY_VERIFY_WITH_TIMEOUT(eng->pipelinePlaying(), 5000);
    }

    void balanceClampsAndNotifies() {
        PlayerState s;
        QSignalSpy spy(&s, &PlayerState::balanceChanged);
        QCOMPARE(s.balance(), 0.0);          // centre by default
        s.setBalance(0.5);
        QCOMPARE(s.balance(), 0.5);
        QCOMPARE(spy.count(), 1);
        s.setBalance(0.5);                    // idempotent: no second signal
        QCOMPARE(spy.count(), 1);
        s.setBalance(-3.0);                   // clamped, not stored raw
        QCOMPARE(s.balance(), -1.0);
        s.setBalance(3.0);
        QCOMPARE(s.balance(), 1.0);
        // A range clamp alone does not filter non-finite input — qBound(-1, NaN,
        // 1) silently yields -1 — so balance must hold its prior 1.0 and stay
        // quiet: non-finite is rejected, not clamped.
        const int before = spy.count();
        s.setBalance(qQNaN());
        QCOMPARE(s.balance(), 1.0);
        QCOMPARE(spy.count(), before);
        s.setBalance(-qInf());
        QCOMPARE(s.balance(), 1.0);
        QCOMPARE(spy.count(), before);
    }

    // setEqBand (EqWindow.qml, applyEqConfig) and eqBands() (MeloUi.eq.bands)
    // share only the engine's state, so a reader with a private shadow array
    // fails.
    void eqBandsReadBackWritesFromAnotherPath() {
        auto eng = makeEngine();
        const auto flat = eng->eqBands();
        QCOMPARE(flat.size(), size_t(10));
        for (double db : flat) QCOMPARE(db, 0.0);

        eng->setEqBand(0, -6.0);
        eng->setEqBand(3, 6.5);
        eng->setEqBand(9, 12.0);

        const auto curve = eng->eqBands();
        QCOMPARE(curve[0], -6.0);
        QCOMPARE(curve[3], 6.5);
        QCOMPARE(curve[9], 12.0);
        QCOMPARE(curve[5], 0.0);     // untouched bands stay flat

        // ...and what it reports is what the audio is doing. Read the same ten
        // values back off equalizer-10bands itself: a setter that stored the dB
        // but never reached the element would pass every assertion above.
        const auto onTheElement = eng->eqBandGains();
        for (int i = 0; i < 10; ++i)
            QVERIFY2(std::fabs(onTheElement[i] - curve[i]) < 1e-9,
                     qPrintable(QStringLiteral("band%1: element %2, reported %3")
                                .arg(i).arg(onTheElement[i]).arg(curve[i])));
    }

    // Catches a clamp-only guard: std::clamp(NaN, -24.0, 12.0) returns NaN, so
    // without an isfinite() check first NaN lands in the reported curve AND in
    // the equalizer's filter coefficients, which silences the output.
    void eqBandClampsAndRejectsNonFinite() {
        auto eng = makeEngine();
        eng->setEqBand(1, 99.0);
        QCOMPARE(eng->eqBands()[1], 12.0);
        eng->setEqBand(2, -99.0);
        QCOMPARE(eng->eqBands()[2], -24.0);

        eng->setEqBand(4, 3.0);
        eng->setEqBand(4, qQNaN());          // rejected, not clamped
        QCOMPARE(eng->eqBands()[4], 3.0);
        eng->setEqBand(4, qInf());
        QCOMPARE(eng->eqBands()[4], 3.0);
    }

    void eqBandIgnoresOutOfRangeIndex() {
        auto eng = makeEngine();
        eng->setEqBand(-1, 9.0);
        eng->setEqBand(10, 9.0);
        for (double db : eng->eqBands()) QCOMPARE(db, 0.0);
    }

    // Preamp is stored and reported in dB — what a Winamp UI shows, and the same
    // unit setEqBand already takes. Winamp's slider is +-12 dB.
    void preampStoresDbClampsAndRejectsNonFinite() {
        auto eng = makeEngine();
        QCOMPARE(eng->preamp(), 0.0);        // unity by default
        eng->setPreamp(6.0);
        QCOMPARE(eng->preamp(), 6.0);
        eng->setPreamp(30.0);
        QCOMPARE(eng->preamp(), 12.0);
        eng->setPreamp(-30.0);
        QCOMPARE(eng->preamp(), -12.0);
        eng->setPreamp(qQNaN());             // rejected, not clamped
        QCOMPARE(eng->preamp(), -12.0);
        eng->setPreamp(-qInf());
        QCOMPARE(eng->preamp(), -12.0);
    }

    // The preamp stage is discovered by name out of the parse-launch string, so
    // a name that does not match leaves it null and setPreamp() silently does
    // nothing while preamp() keeps reporting dB. -1 here means no stage. This
    // also pins the dB -> linear conversion to the RIGHT element.
    void preampReachesItsVolumeElement() {
        auto eng = makeEngine();
        QVERIFY2(eng->preampLinearGain() >= 0, "no volume(preamp) stage in the pipeline");
        QCOMPARE(eng->preampLinearGain(), 1.0);          // 0 dB is unity, not 0
        eng->setPreamp(6.0);
        QVERIFY(std::fabs(eng->preampLinearGain() - 1.99526231) < 1e-6);
        eng->setPreamp(-12.0);
        QVERIFY(std::fabs(eng->preampLinearGain() - 0.25118864) < 1e-6);
        eng->setPreamp(99.0);                            // clamp reaches the audio
        QVERIFY(std::fabs(eng->preampLinearGain() - 3.98107171) < 1e-6);
    }

    // Why the preamp needs its OWN element. equalizer-10bands exposes
    // band0..band9 and nothing else that is a gain — there is no overall level
    // to ride. If a future GStreamer adds one, this fails and the extra `volume`
    // element gets reconsidered deliberately rather than by accident.
    void equalizerHasNoOverallGainProperty() {
        GstElement* eq = gst_element_factory_make("equalizer-10bands", nullptr);
        if (!eq) QSKIP("equalizer-10bands unavailable (gst-plugins-good)");
        GObjectClass* k = G_OBJECT_GET_CLASS(eq);
        for (const char* name : { "gain", "volume", "preamp", "level", "master" })
            QVERIFY2(g_object_class_find_property(k, name) == nullptr, name);
        for (int i = 0; i < 10; ++i) {
            const QByteArray p = QByteArrayLiteral("band") + QByteArray::number(i);
            GParamSpec* ps = g_object_class_find_property(k, p.constData());
            QVERIFY2(ps, p.constData());
            // Double, so g_object_set collects a double: an integer LITERAL
            // (band0, 0 instead of 0.0) would corrupt the value.
            QCOMPARE(ps->value_type, G_TYPE_DOUBLE);
        }
        gst_object_unref(eq);
    }

    // `volume` takes a linear multiplier (1.0 = unity): dB written in would
    // make 0 dB silence, and db/10 (power) doubles every boost. A real element
    // checks the unit and the varargs spelling.
    void preampDbBecomesLinearGainOnARealVolumeElement() {
        GstElement* vol = gst_element_factory_make("volume", nullptr);
        if (!vol) QSKIP("volume element unavailable (gst-plugins-base)");
        GParamSpec* ps = g_object_class_find_property(G_OBJECT_GET_CLASS(vol), "volume");
        QVERIFY(ps);
        QCOMPARE(ps->value_type, G_TYPE_DOUBLE);

        const struct { double db, linear; } cases[] = {
            {   0.0, 1.0        },
            {   6.0, 1.99526231 },
            {  12.0, 3.98107171 },
            { -12.0, 0.25118864 },
        };
        for (const auto& c : cases) {
            const double lin = dbToLinearGain(c.db);
            QVERIFY2(std::fabs(lin - c.linear) < 1e-6, qPrintable(QString::number(c.db)));
            g_object_set(vol, "volume", lin, nullptr);
            gdouble back = -1;
            g_object_get(vol, "volume", &back, nullptr);
            QVERIFY2(std::fabs(back - c.linear) < 1e-6, qPrintable(QString::number(c.db)));
        }
        // +12 dB must stay inside the element's 0..10 range, or the property
        // silently clamps and the top of the slider does nothing.
        QVERIFY(dbToLinearGain(12.0) <= G_PARAM_SPEC_DOUBLE(ps)->maximum);
        gst_object_unref(vol);
    }
};
QTEST_MAIN(TestAudioEngine)
#include "tst_audioengine.moc"
