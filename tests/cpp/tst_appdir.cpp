// meloAppDir() names the real binary's directory when melo is started through a
// link, as a package's /usr/bin/melo -> /usr/lib/melo/bin/melo is.
#include <QtTest>
#include <QProcess>
#include <QTemporaryDir>
#include <cstdio>

#include "../../src/core/paths.h"

class TestAppDir : public QObject {
    Q_OBJECT
private slots:
    void startedThroughALinkFindsTheRealDirectory() {
        const QString self = QFileInfo(QCoreApplication::applicationFilePath()).canonicalFilePath();
        QTemporaryDir bin;
        QVERIFY(bin.isValid());
        const QString link = bin.path() + QStringLiteral("/melo");
        QVERIFY(QFile::link(self, link));

        QProcess p;
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("TST_APPDIR_PRINT"), QStringLiteral("1"));
        p.setProcessEnvironment(env);
        p.start(link, {});
        QVERIFY(p.waitForFinished(10000));
        QCOMPARE(p.exitCode(), 0);
        const QStringList lines = QString::fromUtf8(p.readAllStandardOutput()).split('\n');
        QVERIFY(lines.size() >= 2);
        QCOMPARE(lines[0], QFileInfo(self).absolutePath());
        // what Qt alone reports differs on Qt 6.12; both must not name the link's dir
        QVERIFY(lines[0] != bin.path());
    }
};

int main(int argc, char** argv) {
    if (qEnvironmentVariableIsSet("TST_APPDIR_PRINT")) {
        QCoreApplication app(argc, argv);
        std::printf("%s\n%s\n", qPrintable(meloAppDir()),
                    qPrintable(QCoreApplication::applicationDirPath()));
        return 0;
    }
    QCoreApplication app(argc, argv);
    TestAppDir t;
    return QTest::qExec(&t, argc, argv);
}

#include "tst_appdir.moc"
