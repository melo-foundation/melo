#include "SidecarProcess.h"
#include "NodeBootstrap.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <cstdio>
#include "../core/LogClock.h"


SidecarProcess::SidecarProcess(QObject* parent) : QObject(parent) {
    proc_.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&proc_, &QProcess::readyReadStandardOutput, this, &SidecarProcess::onReadyRead);
    connect(&proc_, &QProcess::readyReadStandardError, this, [this] {
        for (const QByteArray& l : proc_.readAllStandardError().split('\n'))
            if (!l.trimmed().isEmpty()) std::fprintf(stderr, "[%9.1f] [sidecar] %s\n", meloLogMs(), l.constData());
    });
    connect(&proc_, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &SidecarProcess::onFinished);
}

SidecarProcess::~SidecarProcess() {
    // Without this, ~QProcess kills a live child mid-destruction and the
    // finished() it emits runs onFinished's crash-restart against
    // already-destroyed sibling members: exit heap corruption (intermittent
    // SIGABRT in whatever frees next: QFontCache, thread pools, ...).
    disconnect(&proc_, nullptr, this, nullptr);
    if (proc_.state() != QProcess::NotRunning) {
        // Closing stdin is the shutdown the sidecar honours; SIGKILL skips its exit
        // handler and strands its plugin-host children under init (hosts have no stdin
        // close handler, and Discord's socket keeps its loop alive). Kill only after the
        // timeout.
        proc_.closeWriteChannel();
        if (!proc_.waitForFinished(3000)) {
            std::fprintf(stderr, "[melo] sidecar did not exit on stdin close; killing\n");
            proc_.kill();
            proc_.waitForFinished(2000);
        }
    }
}

QString SidecarProcess::resolveNode() {
    const QByteArray env = qgetenv("MELO_NODE");
    if (!env.isEmpty()) return QString::fromLocal8Bit(env);
#ifdef Q_OS_WIN
    // packaged: node.exe shipped beside melo.exe (see the CI deploy step)
    const QString bundled = QCoreApplication::applicationDirPath() + "/node.exe";
    if (QFileInfo::exists(bundled)) return bundled;
    return QStandardPaths::findExecutable("node");
#else
    // deb/rpm: node shipped beside melo
    const QString dir = QCoreApplication::applicationDirPath();
    if (QFileInfo::exists(dir + "/node")) return dir + "/node";
    // lite AppImage and Arch: system node when it's new enough, else the
    // runtime NodeBootstrap downloaded, if it is still the pinned version.
    // A stale download is removed so the next start fetches the pinned one.
    const QString sys = QStandardPaths::findExecutable("node");
    if (!sys.isEmpty()) {
        const QString v = nodeVersion(sys);
        if (nodeVersionSupported(v)) return sys;
        std::fprintf(stderr, "[melo] system node %s: %s, not used\n", qPrintable(sys),
                     v.isEmpty() ? "did not run" : qPrintable(v + " is below 22.22.2"));
    }
    const QString cached = NodeBootstrap::installedPath();
    if (QFileInfo::exists(cached)) {
        if (nodeVersion(cached) == "v" + NodeBootstrap::pinnedVersion()) return cached;
        QFile::remove(cached);
    }
    return {};
#endif
}

QString SidecarProcess::nodeVersion(const QString& node) {
    QProcess p;
    p.start(node, {"--version"});
    if (!p.waitForFinished(3000)) { p.kill(); return {}; }
    return QString::fromLatin1(p.readAllStandardOutput()).trimmed();   // "v22.19.0"
}

bool SidecarProcess::nodeVersionSupported(const QString& v) {
    if (!v.startsWith(u'v')) return false;
    const int major = v.mid(1).section(u'.', 0, 0).toInt();
    const int minor = v.mid(1).section(u'.', 1, 1).toInt();
    const int patch = v.mid(1).section(u'.', 2, 2).toInt();
    // 22.22.2 is jsdom 30's floor (its engines field: ^22.22.2 || ^24.15.0 ||
    // >=26). It also covers module.registerHooks (22.15), which withholds
    // net/tls/dgram/http from a plugin without rawNetwork.
    if (major == 22) return minor > 22 || (minor == 22 && patch >= 2);
    if (major == 24) return minor >= 15;
    return major >= 26;
}

QString SidecarProcess::resolveBundle() {
    const QByteArray env = qgetenv("MELO_SIDECAR");
    if (!env.isEmpty()) return QString::fromLocal8Bit(env);
    const QString installed = QCoreApplication::applicationDirPath() + "/../share/melo/melo-sidecar.mjs";
    if (QFileInfo::exists(installed)) return installed;
#ifdef MELO_DEV_SIDECAR
    return QStringLiteral(MELO_DEV_SIDECAR);
#else
    return {};
#endif
}

void SidecarProcess::start() {
    const QString node = resolveNode();
    const QString bundle = resolveBundle();
    if (node.isEmpty()) {
#ifdef Q_OS_WIN
        emit permanentlyFailed("Node.js not found (need >= 22.22.2; set MELO_NODE)");
#else
        emit nodeMissing();   // main.cpp starts a NodeBootstrap download, then retries start()
#endif
        return;
    }
    std::fprintf(stderr, "[melo] node: %s (%s)\n", node.toUtf8().constData(),
                 nodeVersion(node).toUtf8().constData());
    if (bundle.isEmpty() || !QFileInfo::exists(bundle)) {
        emit permanentlyFailed("sidecar bundle not found: " + bundle +
                               " (run: pnpm -C sidecar build)");
        return;
    }
    buf_.clear();
    proc_.start(node, {bundle});
    if (!proc_.waitForStarted(5000)) { emit permanentlyFailed("sidecar failed to start"); return; }
    emit started();
}

void SidecarProcess::stop() {
    disconnect(&proc_, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
               this, &SidecarProcess::onFinished);
    proc_.closeWriteChannel();
    if (!proc_.waitForFinished(2000)) proc_.kill();
}

bool SidecarProcess::running() const {
    return proc_.state() == QProcess::Running;
}

void SidecarProcess::sendLine(const QByteArray& jsonLine) {
    if (running()) proc_.write(jsonLine + '\n');
}

void SidecarProcess::onReadyRead() {
    buf_ += proc_.readAllStandardOutput();
    int nl;
    while ((nl = buf_.indexOf('\n')) >= 0) {
        const QByteArray line = buf_.left(nl);
        buf_.remove(0, nl + 1);
        if (!line.trimmed().isEmpty()) emit lineReceived(line);
    }
}

void SidecarProcess::onFinished(int code, QProcess::ExitStatus status) {
    std::fprintf(stderr, "[sidecar] exited code=%d status=%d\n", code, int(status));
    // BEFORE the restart, because a restarted sidecar has not registered its
    // handlers yet. Without this, ready stays true across a crash and QML
    // issues calls the new process can only answer with `unknown method`.
    emit exited();
    if (!restartWindow_.isValid() || restartWindow_.elapsed() > 60000) {
        restartWindow_.restart();
        restarts_ = 0;
    }
    if (++restarts_ > 3) {
        emit permanentlyFailed("sidecar crashed repeatedly");
        return;
    }
    std::fprintf(stderr, "[sidecar] restarting (%d/3)\n", restarts_);
    start();
}
