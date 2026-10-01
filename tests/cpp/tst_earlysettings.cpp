#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>
#include "SettingsStore.h"
#include "SidecarService.h"
#include "ThemeStore.h"

// The saved settings are read from the file before the sidecar is up, so the
// window's first frame already has the saved theme, size and layout.
class TestEarlySettings : public QObject {
    Q_OBJECT

    static void writeSettings(const QString& dir, const QByteArray& body) {
        QFile f(dir + "/settings.v2.json");
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(body);
    }

private slots:
    void theSavedThemeIsActiveBeforeTheSidecar() {
        QTemporaryDir dir;
        qputenv("MELO_CONFIG_DIR", dir.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        QString other;
        for (const QVariant& t : store.themes()) {
            const QString id = t.toMap()["id"].toString();
            if (!id.isEmpty() && id != store.activeId()) { other = id; break; }
        }
        QVERIFY(!other.isEmpty());
        writeSettings(dir.path(), QJsonDocument(QJsonObject{
            {"version", 2}, {"ui", QJsonObject{{"activeThemeId", other}, {"windowW", 1234}}}}).toJson());

        QSignalSpy loaded(&settings, &SettingsStore::loadedChanged);
        QVERIFY(settings.loadLocal());
        QCOMPARE(loaded.count(), 1);
        QVERIFY(settings.loaded());
        QCOMPARE(store.activeId(), other);
        QCOMPARE(settings.uiGet("windowW", 0).toInt(), 1234);
    }

    // No file, or one that will not parse: nothing is loaded, and the sidecar's
    // reply stays the only way in.
    void aMissingOrBrokenFileWaitsForTheSidecar() {
        QTemporaryDir dir;
        qputenv("MELO_CONFIG_DIR", dir.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        QVERIFY(!settings.loadLocal());
        writeSettings(dir.path(), "{ \"ui\": { \"activeThemeId\": ");
        QVERIFY(!settings.loadLocal());
        QVERIFY(!settings.loaded());
    }
};

QTEST_MAIN(TestEarlySettings)
#include "tst_earlysettings.moc"
