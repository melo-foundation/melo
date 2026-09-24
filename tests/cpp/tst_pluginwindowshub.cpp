#include <QtTest>
#include <QVariantList>
#include "PluginWindowsHub.h"
#include "PluginWindowHost.h"

// The forwarder Main.qml gets for plugin windows. Only the empty hub is driven
// (a populated one needs real windows, covered by
// tst_windowsnap/tst_windowshape): it must answer with nothing, not a null entry
// Main.qml would pass to KWin.
class TstHub : public QObject {
    Q_OBJECT
private slots:
    void emptyHubHasNoOpacityEntries() {
        PluginWindowsHub hub;
        QCOMPARE(hub.opacityEntries().size(), 0);
        QVERIFY(hub.isEmpty());
    }
};
QTEST_MAIN(TstHub)
#include "tst_pluginwindowshub.moc"
