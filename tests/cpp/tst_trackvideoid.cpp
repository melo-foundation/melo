#include <QtTest>
#include "TrackVideoId.h"

class TstTrackVideoId : public QObject {
    Q_OBJECT
private slots:
    void youtubeTrackReportsItsId() {
        QCOMPARE(reportedVideoId("dQw4w9WgXcQ", "", ""), QString("dQw4w9WgXcQ"));
        QCOMPARE(reportedVideoId("dQw4w9WgXcQ", "youtube", ""), QString("dQw4w9WgXcQ"));
    }
    void linkedImportReportsItsVideo() {
        QCOMPARE(reportedVideoId("local-abc", "", "dQw4w9WgXcQ"), QString("dQw4w9WgXcQ"));
        QCOMPARE(reportedVideoId("local-abc", "", ""), QString());
    }
    // a plugin returning real video ids would write into the user's watch history
    void pluginTrackNeverReports() {
        QCOMPARE(reportedVideoId("dQw4w9WgXcQ", "my-plugin", ""), QString());
        QCOMPARE(reportedVideoId("local-x", "my-plugin", "dQw4w9WgXcQ"), QString());
    }
    // suggestions and pictures follow any YouTube id; only reports need the 11-character form
    void youtubeVideoFollowsTheSourceRuleOnly() {
        QCOMPARE(youtubeVideoOf("quiet20", "", ""), QString("quiet20"));
        QCOMPARE(youtubeVideoOf("dQw4w9WgXcQ", "my-plugin", ""), QString());
        QCOMPARE(youtubeVideoOf("local-x", "my-plugin", "dQw4w9WgXcQ"), QString());
        QCOMPARE(youtubeVideoOf("local-abc", "", "dQw4w9WgXcQ"), QString("dQw4w9WgXcQ"));
    }
    void malformedIdNeverReports() {
        QCOMPARE(reportedVideoId("dQw4w9WgXcQ&list=x", "", ""), QString());
        QCOMPARE(reportedVideoId("smp:1", "", ""), QString());
    }
};

QTEST_GUILESS_MAIN(TstTrackVideoId)
#include "tst_trackvideoid.moc"
