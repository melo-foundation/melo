#include "NodeBootstrap.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QNetworkReply>
#include <QProcess>
#include <cstdio>

// Pinned runtime — bump both together (sha from nodejs.org/dist/vX/SHASUMS256.txt,
// linux-x64.tar.xz line)
static const char* kNodeVersion = "22.23.2";
static const char* kNodeSha256  = "d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307";

QString NodeBootstrap::installedPath() {
    // same user-writable bin dir the sidecar keeps yt-dlp in
    return QDir::homePath() + "/.local/share/melo/bin/node";
}

void NodeBootstrap::download() {
#ifdef Q_OS_WIN
    fail("bundled node.exe missing (reinstall melo)");   // Windows never downloads
#else
    if (active_) return;
    error_.clear();
    active_ = true;
    progress_ = 0;
    receivedMB_ = totalMB_ = 0;
    emit stateChanged();

    const QString url = QStringLiteral("https://nodejs.org/dist/v%1/node-v%1-linux-x64.tar.xz")
                            .arg(QLatin1String(kNodeVersion));
    QNetworkReply* reply = nam_.get(QNetworkRequest(QUrl(url)));
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 rec, qint64 total) {
        receivedMB_ = int(rec / (1024 * 1024));
        totalMB_ = int(total / (1024 * 1024));
        progress_ = total > 0 ? double(rec) / double(total) : 0;
        emit stateChanged();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) { fail(reply->errorString()); return; }
        const QByteArray tar = reply->readAll();
        const QByteArray sha = QCryptographicHash::hash(tar, QCryptographicHash::Sha256).toHex();
        if (sha != kNodeSha256) { fail("checksum mismatch"); return; }

        QDir dir(QFileInfo(installedPath()).absolutePath());
        if (!dir.mkpath(".")) { fail("cannot create " + dir.absolutePath()); return; }
        const QString tarPath = dir.filePath("node.tar.xz.part");
        {
            QFile f(tarPath);
            if (!f.open(QIODevice::WriteOnly) || f.write(tar) != tar.size()) {
                fail("cannot write " + tarPath);
                return;
            }
        }
        QProcess untar;
        untar.start("tar", {"-xJf", tarPath, "-C", dir.absolutePath(), "--strip-components=2",
                            QStringLiteral("node-v%1-linux-x64/bin/node").arg(QLatin1String(kNodeVersion))});
        const bool done = untar.waitForFinished(120000);
        QFile::remove(tarPath);
        if (!done || untar.exitStatus() != QProcess::NormalExit || untar.exitCode() != 0
            || !QFile::exists(installedPath())) {
            fail("extract failed");
            return;
        }
        QFile::setPermissions(installedPath(),
                              QFile::permissions(installedPath()) | QFileDevice::ExeOwner
                                  | QFileDevice::ExeGroup | QFileDevice::ExeOther);
        std::fprintf(stderr, "[node-bootstrap] installed v%s at %s\n", kNodeVersion,
                     installedPath().toUtf8().constData());
        active_ = false;
        progress_ = 1;
        emit stateChanged();
        emit finished(true);
    });
#endif
}

void NodeBootstrap::fail(const QString& why) {
    std::fprintf(stderr, "[node-bootstrap] failed: %s\n", why.toUtf8().constData());
    active_ = false;
    error_ = why;
    emit stateChanged();
    emit finished(false);
}
