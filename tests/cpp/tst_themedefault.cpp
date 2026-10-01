#include <QtTest>
#include <QTemporaryDir>
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

    // Picking a colour names it, as the onboarding and settings rows show it
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
};

QTEST_MAIN(TestThemeDefault)
#include "tst_themedefault.moc"
