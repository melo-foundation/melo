#include <QtTest>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include "ThemeFormat.h"
#include "SettingsStore.h"
#include "SidecarService.h"
#include "ThemeStore.h"

// A fresh install starts on the System theme with nothing see-through, and
// the transparency row matches its Off preset rather than reading Custom.
class TestThemeDefault : public QObject {
    Q_OBJECT
    QTemporaryDir dir_;

private slots:
    void aFreshInstallFollowsTheSystemAndIsSolid() {
        QVERIFY(dir_.isValid());
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        QCOMPARE(store.activeId(), QStringLiteral("system"));
        QCOMPARE(store.matchingPreset(QStringLiteral("transparency")), QStringLiteral("bi-tr-off"));
    }

    // An applied palette preset is the one matched: the onboarding and settings
    // rows show the match as the picked colour
    void aPickedColourIsTheOneMatched() {
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        const QString before = store.matchingPreset(QStringLiteral("palette"));
        QString other;
        for (const QVariant& v : store.presets(QStringLiteral("palette"))) {
            const QString id = v.toMap()["id"].toString();
            if (id != before) { other = id; break; }
        }
        QVERIFY(!other.isEmpty());
        store.applyPreset(QStringLiteral("palette"), other);
        QCOMPARE(store.matchingPreset(QStringLiteral("palette")), other);
    }

    // Each transparency preset sets the video's and the visualizer's mode, is
    // matched after, and leaves a custom value alone.
    void presetsSetTheVideoAndVisualizerModes() {
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        store.setThemeSetting(QStringLiteral("videoOpacity"), 0.4);
        const struct { const char* id; const char* video; const char* vis; } want[] = {
            {"bi-tr-off", "opaque", "opaque"}, {"bi-tr-glass", "opaque", "master"},
            {"bi-tr-frosted", "master", "master"}, {"bi-tr-clear", "opaque", "master"},
        };
        for (const auto& w : want) {
            store.applyPreset(QStringLiteral("transparency"), QLatin1String(w.id));
            QCOMPARE(store.settings().value("videoOpacityMode").toString(), QLatin1String(w.video));
            QCOMPARE(store.settings().value("visualizerOpacityMode").toString(), QLatin1String(w.vis));
            QCOMPARE(store.matchingPreset(QStringLiteral("transparency")), QLatin1String(w.id));
            QCOMPARE(store.settings().value("videoOpacity").toDouble(), 0.4);
        }
        // a custom mode is no preset
        store.setThemeSetting(QStringLiteral("videoOpacityMode"), QStringLiteral("custom"));
        QVERIFY(store.matchingPreset(QStringLiteral("transparency")).isEmpty());
    }

    // The section's Theme (SettingsWindow resetSection("transparency")) clears
    // the modes and values with the rest of it.
    void theThemeResetClearsThem() {
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        store.setThemeSetting(QStringLiteral("videoOpacityMode"), QStringLiteral("custom"));
        store.setThemeSetting(QStringLiteral("videoOpacity"), 0.3);
        store.setThemeSetting(QStringLiteral("visualizerOpacityMode"), QStringLiteral("master"));
        store.setThemeSetting(QStringLiteral("visualizerOpacity"), 0.2);
        QVERIFY(store.partDirty(QStringLiteral("transparency")));
        store.discardPart(QStringLiteral("transparency"));
        store.discardPart(QStringLiteral("surfaces"));
        for (const char* k : {"videoOpacityMode", "videoOpacity", "visualizerOpacityMode", "visualizerOpacity"})
            QVERIFY2(!settings.uiHas(QLatin1String(k)), k);
        QCOMPARE(store.settings().value("videoOpacityMode").toString(), QStringLiteral("opaque"));
        QCOMPARE(store.settings().value("visualizerOpacityMode").toString(), QStringLiteral("opaque"));
        QCOMPARE(store.settings().value("videoOpacity").toDouble(), 1.0);
        QVERIFY(!store.partDirty(QStringLiteral("transparency")));
        QCOMPARE(store.matchingPreset(QStringLiteral("transparency")), QStringLiteral("bi-tr-off"));
    }

    // An older melo's visualizerBg in the user's settings becomes the mode.
    void anOldVisualizerSettingBecomesTheMode() {
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        settings.uiSet(QStringLiteral("visualizerBg"), QStringLiteral("transparent"));
        QVERIFY(!settings.uiHas(QStringLiteral("visualizerBg")));
        QCOMPARE(settings.uiGet(QStringLiteral("visualizerOpacityMode")).toString(), QStringLiteral("master"));
        QCOMPARE(store.settings().value("visualizerOpacityMode").toString(), QStringLiteral("master"));
        settings.uiSet(QStringLiteral("visualizerBg"), QStringLiteral("solid"));
        QVERIFY(!settings.uiHas(QStringLiteral("visualizerBg")));
        // a mode already set is kept
        QCOMPARE(settings.uiGet(QStringLiteral("visualizerOpacityMode")).toString(), QStringLiteral("master"));
        QVERIFY(!store.settings().contains("visualizerBg"));
    }

    // ...and in a theme file, which is rewritten without it.
    void anOldThemeFileIsMigrated() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        qputenv("MELO_CONFIG_DIR", dir.path().toLocal8Bit());
        QVERIFY(QDir().mkpath(dir.path() + "/themes"));
        auto write = [&](const char* id, const QJsonObject& s) {
            QFile f(dir.path() + "/themes/" + id + ".json");
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QJsonDocument(QJsonObject{{"version", ThemeFormat::kThemeVersion}, {"id", id}, {"name", id},
                                              {"palette", QJsonObject{{"window", "#101010"}}},
                                              {"settings", s}}).toJson());
        };
        write("glass", {{"opacityScale", 0.5}, {"visualizerBg", "transparent"}});
        write("solid", {{"opacityScale", 1.0}, {"visualizerBg", "solid"}});
        // no transparency part: it does not gain one
        write("bare", {{"visualizerBg", "transparent"}});
        SidecarService sidecar;
        SettingsStore settings(&sidecar);
        ThemeStore store(&settings);
        auto read = [&](const char* id) {
            QFile f(dir.path() + "/themes/" + id + ".json");
            return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()).object()["settings"].toObject()
                                               : QJsonObject{};
        };
        QCOMPARE(read("glass")["visualizerOpacityMode"].toString(), QStringLiteral("master"));
        QCOMPARE(read("solid")["visualizerOpacityMode"].toString(), QStringLiteral("opaque"));
        QVERIFY(!read("bare").contains("visualizerOpacityMode"));
        for (const char* id : {"glass", "solid", "bare"}) QVERIFY2(!read(id).contains("visualizerBg"), id);
        QVERIFY(!store.partsOfTheme(QStringLiteral("bare")).contains(QStringLiteral("transparency")));
        store.setActive(QStringLiteral("glass"));
        QCOMPARE(store.settings().value("visualizerOpacityMode").toString(), QStringLiteral("master"));
    }
};

QTEST_MAIN(TestThemeDefault)
#include "tst_themedefault.moc"
