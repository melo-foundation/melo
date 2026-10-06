#include <QtTest>
#include <QJsonArray>
#include "VideoRequest.h"
#include "PlayerState.h"

// The request the player sends, and the state QML reads.
class TstVideoWanted : public QObject {
    Q_OBJECT
private slots:
    void requestCarriesTheCapAndTheCodecs() {
        const QJsonObject p = videoRequestParams("abc", 1080, {"av1", "vp9"});
        QCOMPARE(p["videoId"].toString(), QStringLiteral("abc"));
        QCOMPARE(p["maxHeight"].toInt(), 1080);
        QCOMPARE(p["codecs"].toArray(), QJsonArray({"av1", "vp9"}));
    }
    void anUnknownQualityIsTheDefault() {
        QCOMPARE(videoRequestParams("abc", QVariant(), {})["maxHeight"].toInt(), 720);
        QCOMPARE(videoRequestParams("abc", "nonsense", {})["maxHeight"].toInt(), 720);
        QCOMPARE(videoRequestParams("abc", 4320, {})["maxHeight"].toInt(), 720);
        QCOMPARE(videoRequestParams("abc", "480", {})["maxHeight"].toInt(), 480);
    }
    void theBotWallOffersPlaybackCookies() {
        PlayerState s;
        s.setErrorWithCode("x", -32040);
        QCOMPARE(s.errorAction(), QStringLiteral("playbackCookies"));
    }
    void stateDefaultsAreOff() {
        PlayerState s;
        QCOMPARE(s.videoWanted(), false);
        QCOMPARE(s.hasVideo(), false);
        QCOMPARE(s.videoSupported(), false);
        QSignalSpy spy(&s, &PlayerState::videoWantedChanged);
        s.setVideoWanted(true);
        s.setVideoWanted(true);
        QCOMPARE(spy.count(), 1);
        QSignalSpy supported(&s, &PlayerState::videoSupportedChanged);
        s.setVideoSupported(true);
        s.setVideoSupported(true);
        QCOMPARE(supported.count(), 1);
        QCOMPARE(s.videoSupported(), true);
        QCOMPARE(s.videoPending(), false);
        QSignalSpy pending(&s, &PlayerState::videoPendingChanged);
        s.setVideoPending(true);
        s.setVideoPending(true);
        QCOMPARE(pending.count(), 1);
        QCOMPARE(s.videoPending(), true);
    }
};
QTEST_GUILESS_MAIN(TstVideoWanted)
#include "tst_videowanted.moc"
