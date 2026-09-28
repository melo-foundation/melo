#pragma once
#include <QString>
#include <QStringList>

// How melo can keep its windows above others on this session:
//   "kwin"  a KWin script sets keepAbove (Plasma 6, Wayland or X11)
//   "flag"  Qt::WindowStaysOnTopHint, which the window system honours (X11)
//   "menu"  the compositor's window menu (xdg_toplevel.show_window_menu), whose
//           "Always on Top" entry the user picks; melo never learns the state
//   "none"  nothing
// Wayland has no request for "above". Every xdg-shell compositor advertises
// xdg_wm_base, so the protocol cannot say which one draws a window menu with
// that entry: the desktop name decides. KDE is listed for KWin sessions where
// the scripting bus is unreachable (a sandbox) or Plasma 5, whose scripts melo
// cannot run; KWin's menu has "Keep Above".
//
// `override` is MELO_PIN_MODE, for testing a mode on a session that would not
// pick it. An unknown value is ignored.
inline QString pinModeFor(const QString& platform, const QString& desktops,
                          bool kwinAvailable, const QString& override = {}) {
    static const QStringList modes{QStringLiteral("kwin"), QStringLiteral("flag"),
                                   QStringLiteral("menu"), QStringLiteral("none")};
    const QString forced = override.trimmed().toLower();
    if (modes.contains(forced)) return forced;
    if (kwinAvailable) return QStringLiteral("kwin");
    if (platform == QLatin1String("xcb")) return QStringLiteral("flag");
    if (!platform.startsWith(QLatin1String("wayland"))) return QStringLiteral("none");
    static const QStringList withMenu{
        QStringLiteral("gnome"), QStringLiteral("cinnamon"), QStringLiteral("x-cinnamon"),
        QStringLiteral("labwc"), QStringLiteral("pantheon"), QStringLiteral("budgie"),
        QStringLiteral("budgie-desktop"), QStringLiteral("xfce"), QStringLiteral("kde")};
    for (const QString& d : desktops.split(QLatin1Char(':'), Qt::SkipEmptyParts))
        if (withMenu.contains(d.trimmed().toLower())) return QStringLiteral("menu");
    return QStringLiteral("none");
}

// Whether melo drives KWin through its scripting API. Plasma 6 only: Plasma 5
// names workspace.windowList() clientList(), and every script melo loads calls
// it. `kdeSessionVersion` is KDE_SESSION_VERSION; unset or unreadable counts
// as Plasma 6, since a launcher can strip the variable and Plasma 5 is the rare case.
// Wayland and X11 clients alike; offscreen and the rest never.
inline bool kwinScriptingFor(const QString& platform, bool kwinOnBus,
                             const QString& kdeSessionVersion) {
    if (!kwinOnBus) return false;
    if (platform != QLatin1String("xcb") && !platform.startsWith(QLatin1String("wayland")))
        return false;
    bool ok = false;
    const int v = kdeSessionVersion.trimmed().toInt(&ok);
    return !ok || v >= 6;
}
