#include <QtTest>

#include "PinMode.h"

// Which pin route a session gets: KWin's script, the X11 hint, the
// compositor's window menu, or nothing.
class TstPinMode : public QObject {
    Q_OBJECT
private slots:
    void decides_data() {
        QTest::addColumn<QString>("platform");
        QTest::addColumn<QString>("desktops");
        QTest::addColumn<bool>("kwin");
        QTest::addColumn<QString>("forced");
        QTest::addColumn<QString>("want");

        QTest::newRow("plasma wayland") << "wayland" << "KDE" << true << "" << "kwin";
        QTest::newRow("kwin beats a gnome name") << "wayland" << "GNOME" << true << "" << "kwin";
        QTest::newRow("x11 session") << "xcb" << "GNOME" << false << "" << "flag";
        QTest::newRow("plasma 6 x11") << "xcb" << "KDE" << true << "" << "kwin";
        QTest::newRow("plasma 5 x11") << "xcb" << "KDE" << false << "" << "flag";
        QTest::newRow("plasma 5 wayland") << "wayland" << "KDE" << false << "" << "menu";
        QTest::newRow("gnome") << "wayland" << "GNOME" << false << "" << "menu";
        QTest::newRow("ubuntu") << "wayland" << "ubuntu:GNOME" << false << "" << "menu";
        QTest::newRow("case") << "wayland" << "gnome" << false << "" << "menu";
        QTest::newRow("wayland-egl") << "wayland-egl" << "GNOME" << false << "" << "menu";
        QTest::newRow("cinnamon") << "wayland" << "X-Cinnamon" << false << "" << "menu";
        QTest::newRow("labwc") << "wayland" << "labwc:wlroots" << false << "" << "menu";
        QTest::newRow("pantheon") << "wayland" << "Pantheon" << false << "" << "menu";
        QTest::newRow("budgie") << "wayland" << "Budgie:GNOME" << false << "" << "menu";
        QTest::newRow("xfce") << "wayland" << "XFCE" << false << "" << "menu";
        QTest::newRow("sandboxed plasma") << "wayland" << "KDE" << false << "" << "menu";
        QTest::newRow("sway") << "wayland" << "sway" << false << "" << "none";
        QTest::newRow("hyprland") << "wayland" << "Hyprland" << false << "" << "none";
        QTest::newRow("no desktop") << "wayland" << "" << false << "" << "none";
        QTest::newRow("gnomeish is not gnome") << "wayland" << "GNOMEISH" << false << "" << "none";
        QTest::newRow("offscreen") << "offscreen" << "GNOME" << false << "" << "none";
        QTest::newRow("forced menu") << "wayland" << "KDE" << true << "menu" << "menu";
        QTest::newRow("forced none") << "xcb" << "" << false << " NONE " << "none";
        QTest::newRow("forced flag") << "wayland" << "sway" << false << "flag" << "flag";
        QTest::newRow("unknown override ignored") << "xcb" << "" << false << "above" << "flag";
    }
    void decides() {
        QFETCH(QString, platform);
        QFETCH(QString, desktops);
        QFETCH(bool, kwin);
        QFETCH(QString, forced);
        QFETCH(QString, want);
        QCOMPARE(pinModeFor(platform, desktops, kwin, forced), want);
    }

    // Whether KWin's scripting API is the one melo's scripts are written for.
    void kwinScripting_data() {
        QTest::addColumn<QString>("platform");
        QTest::addColumn<bool>("onBus");
        QTest::addColumn<QString>("version");
        QTest::addColumn<bool>("want");

        QTest::newRow("plasma 6 wayland") << "wayland" << true << "6" << true;
        QTest::newRow("plasma 6 x11") << "xcb" << true << "6" << true;
        QTest::newRow("plasma 7") << "wayland" << true << "7" << true;
        QTest::newRow("wayland-egl") << "wayland-egl" << true << "6" << true;
        QTest::newRow("plasma 5 x11") << "xcb" << true << "5" << false;
        QTest::newRow("plasma 5 wayland") << "wayland" << true << "5" << false;
        QTest::newRow("version unset") << "xcb" << true << "" << true;
        QTest::newRow("version junk") << "xcb" << true << "six" << true;
        QTest::newRow("no kwin on the bus") << "xcb" << false << "6" << false;
        QTest::newRow("offscreen") << "offscreen" << true << "6" << false;
        QTest::newRow("padded") << "wayland" << true << " 6 " << true;
    }
    void kwinScripting() {
        QFETCH(QString, platform);
        QFETCH(bool, onBus);
        QFETCH(QString, version);
        QFETCH(bool, want);
        QCOMPARE(kwinScriptingFor(platform, onBus, version), want);
    }
};

QTEST_APPLESS_MAIN(TstPinMode)
#include "tst_pinmode.moc"
