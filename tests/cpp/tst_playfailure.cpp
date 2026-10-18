#include <QtTest>
#include <QFile>
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
