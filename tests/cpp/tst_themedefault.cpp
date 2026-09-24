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
};

QTEST_MAIN(TestThemeDefault)
#include "tst_themedefault.moc"
