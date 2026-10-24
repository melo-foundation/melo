#pragma once

#include <QFileInfo>
#include <QString>

// The program that starts melo again. In the anylinux AppImage melo's own file is
// shared/bin/melo, which runs only through sharun's bin/melo: started directly it
// meets the host's loader and libraries and dies.
inline QString selfLaunchPath(const QString& appFile, const QString& sharunDir) {
    if (sharunDir.isEmpty()) return appFile;
    const QString launcher = sharunDir + QStringLiteral("/bin/") + QFileInfo(appFile).fileName();
    return QFileInfo(launcher).isExecutable() ? launcher : appFile;
}
