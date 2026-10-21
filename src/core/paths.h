#pragma once
#include <QCoreApplication>
#include <QString>
#include <QDir>
#include <QFileInfo>

// melo's config/data directory: the sidecar's "dataDir" (SidecarService::initialize),
// SettingsStore::dataDir(), and the root of plugins/ and plugin-data/. Do not
// re-derive the path. MELO_CONFIG_DIR lets a test instance run beside a live melo
// without racing its settings, library and cookie files.
inline QString meloConfigDir() {
    const QByteArray env = qgetenv("MELO_CONFIG_DIR");
    if (!env.isEmpty()) return QString::fromLocal8Bit(env);
    return QDir::homePath() + "/.config/melo";
}

// The directory melo's bundled files sit beside: melo-qml, presets, fonts, ffmpeg,
// node and ../share/melo. Qt 6.12 takes applicationDirPath from AT_EXECFN, the path
// melo was started by: a package's /usr/bin/melo link would name /usr/bin, so the
// real binary's directory comes from /proc/self/exe. Under sharun (the anylinux
// AppImage) both name the loader, and sharun's bin is the directory.
inline QString meloAppDir() {
    const QString sharun = qEnvironmentVariable("SHARUN_DIR");
    if (!sharun.isEmpty() && QFileInfo::exists(sharun + QStringLiteral("/bin/melo")))
        return sharun + QStringLiteral("/bin");
#ifdef Q_OS_LINUX
    const QString exe = QFileInfo(QStringLiteral("/proc/self/exe")).canonicalFilePath();
    if (!exe.isEmpty()) return QFileInfo(exe).absolutePath();
#endif
    return QCoreApplication::applicationDirPath();
}
