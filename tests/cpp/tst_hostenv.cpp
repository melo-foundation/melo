#include <QtTest>
#include "../../src/core/HostEnv.h"

// A program melo starts gets the system's environment: nothing from the
// AppImage's mount, the system's own entries kept, and unchanged outside one.
class TstHostEnv : public QObject {
    Q_OBJECT
private slots:
    void anAppImagesMountIsLeftOut() {
        qputenv("APPDIR", "/tmp/.mount_meloAb12");
        qputenv("APPIMAGE", "/home/x/melo-x86_64.AppImage");
        qputenv("PATH", "/tmp/.mount_meloAb12/usr/bin:/usr/local/bin:/usr/bin");
        qputenv("LD_LIBRARY_PATH", "/tmp/.mount_meloAb12/usr/lib");
        qputenv("GST_PLUGIN_SYSTEM_PATH", "/tmp/.mount_meloAb12/usr/lib/gstreamer-1.0");
        qputenv("HOME", "/home/x");
        const QProcessEnvironment env = meloHostEnvironment();
        QCOMPARE(env.value("PATH"), QString("/usr/local/bin:/usr/bin"));
        QVERIFY(!env.contains("LD_LIBRARY_PATH"));
        QVERIFY(!env.contains("GST_PLUGIN_SYSTEM_PATH"));
        QVERIFY(!env.contains("APPDIR"));
        QVERIFY(!env.contains("APPIMAGE"));
        QCOMPARE(env.value("HOME"), QString("/home/x"));
    }
    void outsideAnAppImageNothingChanges() {
        qunsetenv("APPDIR");
        qunsetenv("APPIMAGE");
        qputenv("PATH", "/opt/x/bin:/usr/bin");
        qputenv("LD_LIBRARY_PATH", "/opt/x/lib");
        const QProcessEnvironment env = meloHostEnvironment();
        QCOMPARE(env.value("PATH"), QString("/opt/x/bin:/usr/bin"));
        QCOMPARE(env.value("LD_LIBRARY_PATH"), QString("/opt/x/lib"));
    }
};

QTEST_MAIN(TstHostEnv)
#include "tst_hostenv.moc"
