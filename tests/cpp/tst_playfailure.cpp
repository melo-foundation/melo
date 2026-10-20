#include <QtTest>
#include <QSignalSpy>
#include <QDataStream>
#include <QFile>
#include <QUrl>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <gst/gst.h>
#include <memory>

#include "AudioEngine.h"
#include "PcmQueue.h"
#include "PlaybackCoordinator.h"
#include "PlayerState.h"
#include "QueueModel.h"
#include "SettingsStore.h"
#include "SidecarService.h"
#include "SuggestionsModel.h"

// A track that cannot be loaded: the real PlaybackCoordinator against a fake
// sidecar (tests/cpp/data) that answers yt/getStream by video id and logs every request. Checks
// the failure the dialog shows, that nothing plays on, and what each answer asks.

class TestPlayFailure : public QObject {
    Q_OBJECT

    QTemporaryDir dir_;
    QString log_;
    PcmQueue pcm_;
    std::unique_ptr<AudioEngine> engine_;
    std::unique_ptr<SidecarService> sidecar_;
    PlayerState state_;
    QueueModel queue_;
    SuggestionsModel suggestions_;
    std::unique_ptr<SettingsStore> settings_;
    std::unique_ptr<PlaybackCoordinator> coord_;

    // every request the fake got, in order: {m, p}
    QList<QJsonObject> requests() const {
        QList<QJsonObject> out;
        QFile f(log_);
        if (!f.open(QIODevice::ReadOnly)) return out;
        for (const QByteArray& l : f.readAll().split('\n'))
            if (!l.trimmed().isEmpty()) out << QJsonDocument::fromJson(l).object();
        return out;
    }
    QList<QJsonObject> streamRequests(const QString& id) const {
        QList<QJsonObject> out;
        for (const auto& r : requests())
            if (r["m"].toString() == "yt/getStream" && r["p"].toObject()["videoId"].toString() == id)
                out << r["p"].toObject();
        return out;
    }
    static QJsonObject track(const QString& id) {
        return {{"id", id}, {"title", "Track " + id}, {"duration", 100.0}};
    }
    // A fresh engine for each test that plays audio: after a 2 s file ends right after a seek
    // or a stop, the next deck in the same engine can stall before its first buffer.
    void freshPlayer() {
        coord_.reset();
        engine_.reset();
        engine_ = std::make_unique<AudioEngine>(pcm_);
        coord_ = std::make_unique<PlaybackCoordinator>(engine_.get(), sidecar_.get(), &state_,
                                                       &queue_, &suggestions_, settings_.get());
    }
    void playFails(const QStringList& ids, int start = 0) {
        QJsonArray arr;
        for (const auto& id : ids) arr.append(track(id));
        coord_->playQueue(arr, start);
        QTRY_VERIFY_WITH_TIMEOUT(!state_.failCause().isEmpty(), 5000);
    }

private slots:
    void initTestCase() {
        QVERIFY(dir_.isValid());
        const QString bundle = QStringLiteral(MELO_FAKE_SIDECAR);
        QVERIFY(QFile::exists(bundle));
        log_ = dir_.filePath("requests.log");
        qputenv("MELO_SIDECAR", bundle.toLocal8Bit());
        qputenv("MELO_FAKE_LOG", log_.toLocal8Bit());
        qputenv("MELO_CONFIG_DIR", dir_.filePath("cfg").toLocal8Bit());
        qputenv("MELO_FAKE_SINK", "1");
        // silence, 8 kHz mono 16-bit: 2 s for the short and whole tracks, 6 s for a fresh
        // resolve of the short ones, so Retry's seek lands inside the audio
        for (const auto& [name, secs] : {std::pair{"SHORT", 2u}, std::pair{"LONG", 6u}}) {
            const QString wav = dir_.filePath(QString::fromLatin1(name) + ".wav");
            QFile f(wav);
            QVERIFY(f.open(QIODevice::WriteOnly));
            const quint32 rate = 8000, bytes = rate * 2 * secs;
            QDataStream d(&f);
            d.setByteOrder(QDataStream::LittleEndian);
            f.write("RIFF"); d << quint32(36 + bytes); f.write("WAVEfmt ");
            d << quint32(16) << quint16(1) << quint16(1) << rate << quint32(rate * 2) << quint16(2) << quint16(16);
            f.write("data"); d << bytes;
            f.write(QByteArray(int(bytes), '\0'));
            qputenv(QByteArray("MELO_FAKE_") + name + "_URL", QUrl::fromLocalFile(wav).toString().toLocal8Bit());
        }
        gst_init(nullptr, nullptr);
        engine_ = std::make_unique<AudioEngine>(pcm_);
        sidecar_ = std::make_unique<SidecarService>();
        settings_ = std::make_unique<SettingsStore>(sidecar_.get());
        coord_ = std::make_unique<PlaybackCoordinator>(engine_.get(), sidecar_.get(), &state_,
                                                       &queue_, &suggestions_, settings_.get());
        sidecar_->start();
        QTRY_VERIFY_WITH_TIMEOUT(sidecar_->ready(), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(settings_->loaded(), 5000);
    }
    void cleanupTestCase() { coord_.reset(); settings_.reset(); sidecar_.reset(); engine_.reset(); }
    void init() { state_.clearFailure(); state_.setError(QString()); }

    void causeForEveryCode() {
        QCOMPARE(PlayerState::failCauseFor(-32040), QString("guestWall"));
        QCOMPARE(PlayerState::failCauseFor(-32041), QString("browserWall"));
        QCOMPARE(PlayerState::failCauseFor(-32010), QString("signin"));
        QCOMPARE(PlayerState::failCauseFor(-32020), QString("network"));
        QCOMPARE(PlayerState::failCauseFor(-32030), QString("network"));
        QCOMPARE(PlayerState::failCauseFor(-32001), QString("network"));   // RpcClient's timeout
        QCOMPARE(PlayerState::failCauseFor(-32002), QString("network"));   // the sidecar died
        QCOMPARE(PlayerState::failCauseFor(0), QString("other"));          // ok:false
        QCOMPARE(PlayerState::failCauseFor(-32000), QString("other"));
    }

    void failureCarriesCauseAndReason_data() {
        QTest::addColumn<QString>("id");
        QTest::addColumn<QString>("cause");
        QTest::addColumn<QString>("reason");
        QTest::newRow("guest wall") << "guestwall1" << "guestWall" << "YouTube is refusing guest playback from this address.";
        QTest::newRow("browser wall") << "browserwall1" << "browserWall"
                                      << "YouTube is refusing playback from this address, even with your browser's account.";
        QTest::newRow("sign-in") << "signin1" << "signin" << "Your sign-in has expired.";
        QTest::newRow("network") << "network1" << "network" << "Network error";
        QTest::newRow("other") << "unavailable1" << "other" << "This video is unavailable";
    }
    void failureCarriesCauseAndReason() {
        QFETCH(QString, id);
        QFETCH(QString, cause);
        QFETCH(QString, reason);
        state_.setIsPlaying(true);   // the track before was playing
        playFails({id});
        QCOMPARE(state_.failCause(), cause);
        QCOMPARE(state_.failReason(), reason);
        QVERIFY(!state_.loading());
        QVERIFY(!state_.isPlaying());          // the bar does not claim it plays
        QCOMPARE(state_.currentTrack().id, id);   // stays on the track
        QVERIFY(state_.error().isEmpty());      // the dialog, not the fading card
    }

    void retryAsksAgainFresh() {
        playFails({"guestwall2"});
        QCOMPARE(streamRequests("guestwall2").size(), 1);
        QVERIFY(!streamRequests("guestwall2").first().contains("fresh"));
        coord_->answerFailure("retry");
        QTRY_COMPARE(streamRequests("guestwall2").size(), 2);
        QCOMPARE(streamRequests("guestwall2").last()["fresh"].toBool(), true);
        QTRY_COMPARE(state_.failCause(), QString("guestWall"));   // still walled: shown again
    }

    // the relay gave up on the stream: the network failure on the same track, not the
    // next one, at where it stopped; Retry resumes there
    void aStreamTheRelayDroppedIsANetworkFailure() {
        freshPlayer();
        QJsonArray arr{track("dropped1"), track("unavailable9")};
        coord_->playQueue(arr, 0);
        QTRY_VERIFY_WITH_TIMEOUT(!state_.failCause().isEmpty(), 10000);
        QCOMPARE(state_.failCause(), QString("network"));
        QVERIFY2(state_.failReason().startsWith("The connection dropped at 0:0"), qPrintable(state_.failReason()));
        QCOMPARE(queue_.currentIndex(), 0);
        QCOMPARE(state_.currentTrack().id, QString("dropped1"));
        QVERIFY(!state_.isPlaying());
        coord_->answerFailure("retry");
        QVERIFY2(state_.position() >= 1.0, qPrintable(QString::number(state_.position())));
        QTRY_COMPARE(streamRequests("dropped1").size(), 2);
        QCOMPARE(streamRequests("dropped1").last()["fresh"].toBool(), true);
        QTRY_VERIFY_WITH_TIMEOUT(!state_.failCause().isEmpty(), 10000);   // dropped again
        QCOMPARE(state_.failCause(), QString("network"));
        coord_->answerFailure("dismiss");
    }

    // an end well short of the listed length with no word from the relay is the real end
    // under a wrong length: it moves on
    void anEarlyEndWithoutTheRelaysWordAdvances() {
        freshPlayer();
        QJsonArray arr{track("short1"), track("unavailable9")};
        coord_->playQueue(arr, 0);
        QTRY_COMPARE_WITH_TIMEOUT(queue_.currentIndex(), 1, 10000);
        QTRY_VERIFY_WITH_TIMEOUT(!state_.failCause().isEmpty(), 5000);
        QCOMPARE(state_.failCause(), QString("other"));   // unavailable9's own failure
        coord_->answerFailure("dismiss");
    }

    // the relay's word can arrive just after the end: it still counts
    void theRelaysWordJustAfterTheEndCounts() {
        freshPlayer();
        QSignalSpy ended(engine_.get(), &AudioEngine::trackEnded);
        QJsonArray arr{track("short2"), track("unavailable9")};
        coord_->playQueue(arr, 0);
        QTRY_COMPARE_WITH_TIMEOUT(ended.count(), 1, 10000);
        QCOMPARE(queue_.currentIndex(), 0);
        emit sidecar_->streamDropped(QStringLiteral("file:///another"), 1);   // not this stream
        QVERIFY(state_.failCause().isEmpty());
        emit sidecar_->streamDropped(qEnvironmentVariable("MELO_FAKE_SHORT_URL"), 4321);
        QCOMPARE(state_.failCause(), QString("network"));
        QVERIFY2(state_.failReason().startsWith("The connection dropped at 0:0"), qPrintable(state_.failReason()));
        QCOMPARE(state_.currentTrack().id, QString("short2"));
        // Retry plays again from where it stopped
        coord_->answerFailure("retry");
        QTRY_VERIFY_WITH_TIMEOUT(state_.isPlaying() && engine_->position() > 1.2, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(queue_.currentIndex(), 1, 10000);   // no word this time: it moves on
        QTRY_COMPARE_WITH_TIMEOUT(state_.failCause(), QString("other"), 5000);
        coord_->answerFailure("dismiss");
    }

    // the player reconnected after the relay gave up and the stream flowed again: its end is real
    void aStreamThatFlowsAgainEndsNormally() {
        freshPlayer();
        const QString url = qEnvironmentVariable("MELO_FAKE_SHORT_URL");
        QJsonArray arr{track("short3"), track("unavailable9")};
        coord_->playQueue(arr, 0);
        QTRY_VERIFY_WITH_TIMEOUT(state_.isPlaying(), 10000);
        emit sidecar_->streamDropped(url, 4321);
        emit sidecar_->streamResumed(url);
        QTRY_COMPARE_WITH_TIMEOUT(queue_.currentIndex(), 1, 10000);
        QTRY_COMPARE_WITH_TIMEOUT(state_.failCause(), QString("other"), 5000);
        coord_->answerFailure("dismiss");
    }

    // the queue ran out: play starts the last track again
    void playAfterTheQueueRanOutStartsItAgain() {
        freshPlayer();
        QJsonArray arr{track("whole1")};
        coord_->playQueue(arr, 0);
        QTRY_VERIFY_WITH_TIMEOUT(state_.isPlaying(), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(!state_.isPlaying(), 10000);   // played to its end
        QVERIFY(state_.failCause().isEmpty());
        QCOMPARE(streamRequests("whole1").size(), 1);
        coord_->togglePlay();
        QTRY_COMPARE(streamRequests("whole1").size(), 2);
        QTRY_VERIFY_WITH_TIMEOUT(state_.isPlaying(), 10000);
        coord_->stop();
    }

    void skipPlaysTheNextTrack() {
        playFails({"unavailable2", "guestwall3"});
        QCOMPARE(queue_.currentIndex(), 0);
        coord_->answerFailure("skip");
        QCOMPARE(queue_.currentIndex(), 1);
        QTRY_COMPARE(state_.currentTrack().id, QString("guestwall3"));
        QTRY_COMPARE(streamRequests("guestwall3").size(), 1);
    }

    void browserAnswerSwitchesCookiesThenRetries() {
        playFails({"guestwall4"});
        const int before = requests().size();
        coord_->answerFailure("browser");
        QTRY_COMPARE(streamRequests("guestwall4").size(), 2);
        const auto after = requests().mid(before);
        int setAt = -1, streamAt = -1;
        for (int i = 0; i < after.size(); ++i) {
            const auto& r = after[i];
            if (r["m"].toString() == "settings/set"
                && r["p"].toObject()["patch"].toObject()["streamCookieSource"].toString() == "browser") setAt = i;
            if (r["m"].toString() == "yt/getStream" && streamAt < 0) streamAt = i;
        }
        QVERIFY(setAt >= 0);
        QVERIFY(setAt < streamAt);
        QCOMPARE(streamRequests("guestwall4").last()["fresh"].toBool(), true);
    }

    void updateAnswerPullsNightlyThenRetries() {
        playFails({"browserwall2"});
        coord_->answerFailure("update");
        QTRY_COMPARE(streamRequests("browserwall2").size(), 2);
        bool asked = false;
        for (const auto& r : requests())
            if (r["m"].toString() == "ytdlp/setChannel" && r["p"].toObject()["channel"].toString() == "nightly") asked = true;
        QVERIFY(asked);
        QCOMPARE(streamRequests("browserwall2").last()["fresh"].toBool(), true);
    }

    void dismissAndSignInOnlyClose() {
        playFails({"signin2"});
        coord_->answerFailure("signin");
        QVERIFY(state_.failCause().isEmpty());
        QTest::qWait(200);
        QCOMPARE(streamRequests("signin2").size(), 1);
        QCOMPARE(state_.currentTrack().id, QString("signin2"));
    }

    // A walled prefetch stays silent and is asked once, not on every tick.
    void prefetchFailureIsSilentAndNotRepeated() {
        playFails({"guestwall5", "unavailable3"});
        for (int i = 0; i < 6; ++i) {
            QVERIFY(QMetaObject::invokeMethod(engine_.get(), "positionTick",
                                              Q_ARG(double, 1.0 + i), Q_ARG(double, 100.0)));
            QTest::qWait(60);
        }
        QTRY_COMPARE(streamRequests("unavailable3").size(), 1);
        QTest::qWait(200);
        QCOMPARE(streamRequests("unavailable3").size(), 1);
        QCOMPARE(state_.failCause(), QString("guestWall"));   // the playing track's, untouched
    }
};

QTEST_MAIN(TestPlayFailure)
#include "tst_playfailure.moc"
