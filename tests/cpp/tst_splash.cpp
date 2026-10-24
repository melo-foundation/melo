#include <QElapsedTimer>
#include <QProcess>
#include <QtTest>

#include "../../src/core/SelfLaunch.h"

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

    void startsThroughSharunInTheAnylinuxAppImage() {
        QTemporaryDir root;
        QVERIFY(QDir(root.path()).mkpath(QStringLiteral("bin")));
        QVERIFY(QDir(root.path()).mkpath(QStringLiteral("shared/bin")));
        const QString real = root.path() + QStringLiteral("/shared/bin/melo");
        const QString launcher = root.path() + QStringLiteral("/bin/melo");
        for (const QString& f : {real, launcher}) {
            QFile file(f);
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        }
        QCOMPARE(selfLaunchPath(real, root.path()), launcher);
        QCOMPARE(selfLaunchPath(real, QString()), real);
        // no launcher beside it: melo's own file
        QCOMPARE(selfLaunchPath(real, root.path() + QStringLiteral("/elsewhere")), real);
    }
};

QTEST_GUILESS_MAIN(TstSplash)
#include "tst_splash.moc"
