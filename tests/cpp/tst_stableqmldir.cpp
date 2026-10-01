#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QtTest>

#include "StableQmlDir.h"

// An AppImage's QML, copied to a path that stays the same for its build.
class TstStableQmlDir : public QObject {
    Q_OBJECT

    static void write(const QString& path, const QByteArray& body, const QDateTime& mtime) {
        QDir().mkpath(QFileInfo(path).path());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(body);
        f.close();
        QVERIFY(f.open(QIODevice::ReadWrite));
        QVERIFY(f.setFileTime(mtime, QFileDevice::FileModificationTime));
    }
    // one build's QML, as a mount of it shows it
    static void mount(const QString& dir, const QByteArray& mainBody = "Main") {
        const QDateTime built = QDateTime::fromSecsSinceEpoch(1'700'000'000);
        write(dir + "/Main.qml", mainBody, built);
        write(dir + "/components/Card.qml", "Card", built);
    }

private slots:
    // Two mounts of the same build land on one copy, so the second start hits
    // the cache the first one wrote.
    void sameBuildSamePath() {
        QTemporaryDir tmp;
        mount(tmp.path() + "/.mount_a/qml");
        mount(tmp.path() + "/.mount_b/qml");
        const QString root = tmp.path() + "/cache/qml";
        const QString a = stableQmlDir(tmp.path() + "/.mount_a/qml", root);
        const QString b = stableQmlDir(tmp.path() + "/.mount_b/qml", root);
        QVERIFY(a.startsWith(root));
        QCOMPARE(b, a);
        QFile card(a + "/components/Card.qml");
        QVERIFY(card.open(QIODevice::ReadOnly));
        QCOMPARE(card.readAll(), QByteArray("Card"));
    }

    // Another build never reads the old one's files.
    void otherBuildOtherPath() {
        QTemporaryDir tmp;
        mount(tmp.path() + "/.mount_a/qml", "Main v1");
        mount(tmp.path() + "/.mount_b/qml", "Main v2!");
        const QString root = tmp.path() + "/cache/qml";
        const QString a = stableQmlDir(tmp.path() + "/.mount_a/qml", root);
        const QString b = stableQmlDir(tmp.path() + "/.mount_b/qml", root);
        QVERIFY(a != b);
        QFile main(b + "/Main.qml");
        QVERIFY(main.open(QIODevice::ReadOnly));
        QCOMPARE(main.readAll(), QByteArray("Main v2!"));
    }

    // Nowhere to copy to: the mount is used as it is.
    void unwritableFallsBack() {
        QTemporaryDir tmp;
        mount(tmp.path() + "/.mount_a/qml");
        write(tmp.path() + "/file", "not a dir", QDateTime::currentDateTime());
        QCOMPARE(stableQmlDir(tmp.path() + "/.mount_a/qml", tmp.path() + "/file/qml"),
                 tmp.path() + "/.mount_a/qml");
    }

    // Copies no build has used for 30 days go; recent ones stay.
    void oldCopiesArePruned() {
        QTemporaryDir tmp;
        const QString root = tmp.path() + "/cache/qml";
        mount(tmp.path() + "/.mount_a/qml", "Main v1");
        mount(tmp.path() + "/.mount_b/qml", "Main v2!");
        mount(tmp.path() + "/.mount_c/qml", "Main v3!!");
        const QString a = stableQmlDir(tmp.path() + "/.mount_a/qml", root);
        const QString b = stableQmlDir(tmp.path() + "/.mount_b/qml", root);
        QFile stamp(a + "/" + QString::fromLatin1(kStableQmlStamp));
        QVERIFY(stamp.open(QIODevice::ReadWrite));
        QVERIFY(stamp.setFileTime(QDateTime::currentDateTime().addDays(-31),
                                  QFileDevice::FileModificationTime));
        stamp.close();
        stableQmlDir(tmp.path() + "/.mount_c/qml", root);
        QVERIFY(!QFileInfo::exists(a));
        QVERIFY(QFileInfo::exists(b + "/Main.qml"));
    }
};

QTEST_GUILESS_MAIN(TstStableQmlDir)
#include "tst_stableqmldir.moc"
