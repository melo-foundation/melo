#pragma once
#include <QProcessEnvironment>
#include <QStringList>

// The environment of the system around melo, for a program melo starts that is
// not part of it: in an AppImage every entry pointing into the mount goes (a list
// such as PATH keeps its other entries; the anylinux AppRun puts the mount first),
// and the AppImage's own variables with it. Outside an AppImage it is unchanged.
inline QProcessEnvironment meloHostEnvironment() {
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    const QString mount = env.value(QStringLiteral("APPDIR"));
    for (const QString& k : env.keys()) {
        if (mount.isEmpty() || !env.value(k).contains(mount)) continue;
        QStringList keep = env.value(k).split(u':');
        keep.removeIf([&mount](const QString& e) { return e.contains(mount); });
        if (keep.isEmpty()) env.remove(k); else env.insert(k, keep.join(u':'));
    }
    for (const char* k : { "APPDIR", "APPIMAGE", "ARGV0" }) env.remove(QString::fromLatin1(k));
    return env;
}
