#include <QElapsedTimer>
#include <QProcess>
#include <QtTest>

// `melo --splash` (Splash.h): up until melo says its window shows, or melo is
// gone, and never longer.
class TstSplash : public QObject {
    Q_OBJECT

    static void startSplash(QProcess& p) {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
        p.setProcessEnvironment(env);
        p.start(QStringLiteral(MELO_BIN), {QStringLiteral("--splash")});
        QVERIFY(p.waitForStarted(5000));
    }

private slots:
    void staysUpUntilTold() {
        QProcess p;
        startSplash(p);
        QVERIFY(!p.waitForFinished(1500));
        p.kill();
        p.waitForFinished();
    }

    void goesWhenTheWindowShows() {
        QProcess p;
        startSplash(p);
        QTest::qWait(500);
        QElapsedTimer t;
        t.start();
        p.write("x", 1);
        QVERIFY(p.waitForFinished(3000));
        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QCOMPARE(p.exitCode(), 0);
        QVERIFY2(t.elapsed() < 1000, qPrintable(QString::number(t.elapsed())));
    }

    void goesWithMelo() {
        QProcess p;
        startSplash(p);
        QTest::qWait(500);
        p.closeWriteChannel();   // what melo exiting does to the pipe
        QVERIFY(p.waitForFinished(3000));
        QCOMPARE(p.exitCode(), 0);
    }
};

QTEST_GUILESS_MAIN(TstSplash)
#include "tst_splash.moc"
