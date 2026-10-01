#pragma once
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QStringList>

// Qt names a QML cache file after the source's path, and an AppImage mounts at
// a new /tmp/.mount_* each run, which would recompile all of melo's QML on each
// start (2.3 s). So the QML is copied once per build to a fixed path; copied,
// because a mount goes away with its melo while another may still load from it.

// touched on each use; a copy untouched for 30 days is removed
inline constexpr char kStableQmlStamp[] = ".used";

// The build, from each file's path, size and time: an AppImage's files carry
// its build time, so two builds of one version still differ.
inline QString stableQmlKey(const QString& src) {
    QStringList lines;
    const QDir base(src);
    QDirIterator it(src, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QFileInfo f(it.next());
        lines << base.relativeFilePath(f.filePath()) + '\t' + QString::number(f.size()) + '\t'
                     + QString::number(f.lastModified(QTimeZone::UTC).toMSecsSinceEpoch());
    }
    lines.sort();
    return QString::fromLatin1(QCryptographicHash::hash(lines.join('\n').toUtf8(),
                                                        QCryptographicHash::Sha1).toHex().left(16));
}

inline void touchStableQml(const QString& dir) {
    QFile stamp(dir + '/' + QString::fromLatin1(kStableQmlStamp));
    if (stamp.open(QIODevice::WriteOnly | QIODevice::Append))
        stamp.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
}

inline void pruneStableQml(const QString& root, const QString& keep) {
    const QDateTime cutoff = QDateTime::currentDateTime().addDays(-30);
    for (const QFileInfo& d : QDir(root).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        if (d.fileName() == keep) continue;
        const QFileInfo stamp(d.filePath() + '/' + QString::fromLatin1(kStableQmlStamp));
        const QDateTime used = stamp.exists() ? stamp.lastModified() : d.lastModified();
        if (used < cutoff) QDir(d.filePath()).removeRecursively();
    }
}

// The copy of src under root for this build, made if missing; src itself when
// the copy cannot be made.
inline QString stableQmlDir(const QString& src, const QString& root) {
    const QString key = stableQmlKey(src);
    const QString dest = root + '/' + key;
    if (!QFileInfo::exists(dest + "/Main.qml")) {
        // built beside and renamed into place, so a second melo starting now
        // never loads a half-copied tree
        const QString tmp = dest + ".part-" + QString::number(QCoreApplication::applicationPid());
        QDir(tmp).removeRecursively();
        bool ok = QDir().mkpath(tmp);
        const QDir base(src);
        QDirIterator it(src, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
        while (ok && it.hasNext()) {
            const QString from = it.next();
            const QString to = tmp + '/' + base.relativeFilePath(from);
            ok = QDir().mkpath(QFileInfo(to).path()) && QFile::copy(from, to);
        }
        if (!ok || !QDir().rename(tmp, dest)) {
            QDir(tmp).removeRecursively();
            if (!QFileInfo::exists(dest + "/Main.qml")) return src;   // lost a race: dest is the winner's
        }
    }
    touchStableQml(dest);
    pruneStableQml(root, key);
    return dest;
}
