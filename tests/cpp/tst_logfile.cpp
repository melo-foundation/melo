#include <QtTest>
#include <QElapsedTimer>
#include <QTemporaryDir>
#include <cstdio>
#include <QProcess>
#include <fcntl.h>
#include <unistd.h>

#include "LogFile.h"
#include "LogTail.h"

// <config>/logs/melo.log: rotation at the cap, secrets kept out, fd 2 teed into
// it, Qt's messages chained to the handler before, and the tail a report takes.

static QStringList g_prevSaw;
static void prevHandler(QtMsgType, const QMessageLogContext&, const QString& msg) { g_prevSaw << msg; }

static QString readAll(const QString& path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()) : QString();
}

class TstLogFile : public QObject {
    Q_OBJECT
private slots:
    void rotatesAtTheCapKeepingThree() {
        QTemporaryDir d;
        {
            LogFile log(d.path(), 1000, 3);
            for (int i = 0; i < 200; ++i) log.writeLine(QByteArray("line ") + QByteArray::number(i).rightJustified(40, '0'));
            log.flush();
        }
        for (const char* n : {"melo.log", "melo.log.1", "melo.log.2", "melo.log.3"})
            QVERIFY2(QFile::exists(d.filePath(n)), n);
        QVERIFY(!QFile::exists(d.filePath("melo.log.4")));
        for (const char* n : {"melo.log.1", "melo.log.2", "melo.log.3"})
            QVERIFY(QFileInfo(d.filePath(n)).size() < 1100);
        QVERIFY(readAll(d.filePath("melo.log")).contains("line " + QString::number(199).rightJustified(40, '0')));
    }

    void redactsSecrets_data() {
        QTest::addColumn<QByteArray>("line");
        QTest::addColumn<QByteArray>("secret");
        QTest::newRow("googlevideo") << QByteArray("open https://rr3---sn-x.googlevideo.com/videoplayback?expire=1&sig=ABC123 failed") << QByteArray("rr3---sn-x");
        QTest::newRow("cookie header") << QByteArray("Cookie: SAPISID=abcdef; SID=ghijkl") << QByteArray("abcdef");
        QTest::newRow("auth header") << QByteArray("Authorization: SAPISIDHASH 1700000000_deadbeefcafe") << QByteArray("deadbeefcafe");
        QTest::newRow("cookie pair") << QByteArray("set __Secure-3PSID=s3cr3tvalue1 for .youtube.com") << QByteArray("s3cr3tvalue1");
        QTest::newRow("query key") << QByteArray("GET https://ws.audioscrobbler.com/2.0/?method=track.getInfo&api_key=0123456789abcdef0123456789abcdef") << QByteArray("0123456789abcdef");
        QTest::newRow("json token") << QByteArray("{\"visitorData\":\"CgtXYZabc123\",\"ok\":true}") << QByteArray("CgtXYZabc123");
        QTest::newRow("po token") << QByteArray("[potoken] poToken=MnQabcdefghijkl minted") << QByteArray("MnQabcdefghijkl");
    }
    void redactsSecrets() {
        QFETCH(QByteArray, line);
        QFETCH(QByteArray, secret);
        const QByteArray out = LogFile::redact(line);
        QVERIFY2(!out.contains(secret), out.constData());
        QVERIFY2(out.contains("<redacted>") || out.contains("<googlevideo url>"), out.constData());
    }

    void leavesOrdinaryLinesAlone() {
        const QByteArray l = "[  2183.4] [sidecar] [guest-cookies:Default] New cookies: PREF, SOCS";
        QCOMPARE(LogFile::redact(l), l);
        const QByteArray r = "[relay] a1b2 open range=bytes=0- status=206 size=4096";
        QCOMPARE(LogFile::redact(r), r);
    }

    void tailTakesTheLastLinesAcrossRotation() {
        QTemporaryDir d;
        {
            LogFile log(d.path(), 4000, 3);
            for (int i = 0; i < 300; ++i) log.writeLine("n" + QByteArray::number(i));
        }
        const QStringList t = meloLogTail(d.path(), 100);
        QCOMPARE(t.size(), 100);
        QCOMPARE(t.last(), QString("n299"));
        QCOMPARE(t.first(), QString("n200"));
    }

    // fd 2 and Qt's messages land in the file once each; the handler before
    // still gets every message
    void teesStderrAndChainsTheHandlerBefore() {
        QTemporaryDir d;
        g_prevSaw.clear();
        const QtMessageHandler before = qInstallMessageHandler(&prevHandler);
        QVERIFY(LogFile::startTee(d.path(), false));
        std::fprintf(stderr, "[melo] tee probe one\n");
        qWarning("qt probe two");
        // a message the handler before prints to stderr itself, as Qt's default does
        qInstallMessageHandler(nullptr);
        LogFile::stopTee();
        qInstallMessageHandler(before);
        QVERIFY(g_prevSaw.contains("qt probe two"));
        const QString text = readAll(d.filePath("melo.log"));
        QVERIFY2(text.contains("[melo] tee probe one\n"), qPrintable(text));
        QCOMPARE(text.count("qt probe two"), 1);
    }

    void qtsOwnStderrCopyIsNotLoggedTwice() {
        QTemporaryDir d;
        // the handler before prints to fd 2 as Qt's default does without journald
        const QtMessageHandler before = qInstallMessageHandler([](QtMsgType t, const QMessageLogContext& c, const QString& m) {
            std::fprintf(stderr, "%s\n", qPrintable(qFormatLogMessage(t, c, m)));
        });
        QVERIFY(LogFile::startTee(d.path(), false));
        qWarning("qt probe three");
        qInstallMessageHandler(nullptr);
        LogFile::stopTee();
        qInstallMessageHandler(before);
        QCOMPARE(readAll(d.filePath("melo.log")).count("qt probe three"), 1);
    }

    // A child started while the tee runs writes to stderr after the tee is gone:
    // it lives, its line reaches the real stderr, and melo's own line the log.
    void childrenGetTheRealStderr() {
        QTemporaryDir d;
        const QString realErr = d.filePath("real-stderr.txt");
        const int saved = ::dup(2);
        const int f = ::open(QFile::encodeName(realErr).constData(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
        ::dup2(f, 2); ::close(f);

        QVERIFY(LogFile::startTee(d.path(), false));
        std::fprintf(stderr, "[melo] own line\n");
        QProcess child;
        child.setProcessChannelMode(QProcess::ForwardedChannels);
        child.start("/bin/sh", {"-c", "sleep 0.4; echo child-line >&2; echo child-again >&2"});
        QVERIFY(child.waitForStarted());
        LogFile::stopTee();   // the tee's read end is closed before the child writes
        QVERIFY(child.waitForFinished(5000));

        ::dup2(saved, 2); ::close(saved);
        QCOMPARE(child.exitStatus(), QProcess::NormalExit);   // SIGPIPE would be a crash exit
        QCOMPARE(child.exitCode(), 0);
        const QString real = readAll(realErr);
        QVERIFY2(real.contains("child-line\nchild-again\n"), qPrintable(real));
        QVERIFY2(real.contains("[melo] own line\n"), qPrintable(real));
        const QString log = readAll(d.filePath("melo.log"));
        QVERIFY2(log.contains("[melo] own line\n"), qPrintable(log));
        QVERIFY(!log.contains("child-line"));
    }

    // the GUI thread's cost: a write to a pipe a worker drains
    void teeCostsLittle() {
        QTemporaryDir d;
        QVERIFY(LogFile::startTee(d.path(), false));
        QElapsedTimer t; t.start();
        for (int i = 0; i < 2000; ++i) std::fprintf(stderr, "[bench] line %d of a typical length for melo's log output\n", i);
        const qint64 ns = t.nsecsElapsed();
        LogFile::stopTee();
        std::printf("tee: %.2f us per line\n", ns / 2000.0 / 1000.0);
        QVERIFY(ns / 2000 < 200000);   // well under 0.2 ms a line
        QCOMPARE(readAll(d.filePath("melo.log")).count("[bench] line"), 2000);
    }
};

QTEST_GUILESS_MAIN(TstLogFile)
#include "tst_logfile.moc"
