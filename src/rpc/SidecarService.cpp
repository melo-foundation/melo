#include "SidecarService.h"
#include "SidecarProcess.h"
#include "RpcClient.h"
#include "paths.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QDir>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QStyleHints>
#include <cstdio>

SidecarService::SidecarService(QObject* parent)
    : QObject(parent),
      proc_(new SidecarProcess(this)),
      rpc_(new RpcClient(proc_, this)) {
    connect(proc_, &SidecarProcess::started, this, &SidecarService::initialize);
    // The sidecar died. It is not ready again until initialize() has answered,
    // which is what sets ready_ back to true.
    connect(proc_, &SidecarProcess::exited, this, [this] {
        if (!ready_) return;
        ready_ = false;
        emit readyChanged();
    });
    connect(proc_, &SidecarProcess::nodeMissing, this, &SidecarService::nodeMissing);
    connect(proc_, &SidecarProcess::permanentlyFailed, this, [this](const QString& r) {
        ready_ = false;
        emit readyChanged();
        emit rpcFailed("sidecar", r);
    });
    connect(rpc_, &RpcClient::notification, this,
            [this](const QString& method, const QJsonObject& params) {
        if (method == "library/changed") emit libraryChanged();
        else if (method == "job/done")
            emit jobDone(params["jobId"].toString(), params["ok"].toBool(), params["result"].toObject());
        else if (method == "plugins/changed")
            emit pluginsChanged(params.value("plugins").toArray());
        else if (method == "ytdlp/stale")
            emit ytdlpStale(params.value("message").toString());
    });
}

void SidecarService::start() {
    proc_->start();
}

RpcCall* SidecarService::call(const QString& method, const QJsonObject& params, int timeoutMs) {
    return rpc_->call(method, params, timeoutMs);
}

void SidecarService::initialize() {
    const QString dataDir = meloConfigDir();
    const QString musicDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
#ifdef Q_OS_WIN
    // user-writable self-updating copy under the config dir; seed from the
    // yt-dlp.exe bundled beside melo.exe (CI deploy), else PATH
    const QString ytdlp = meloConfigDir() + "/bin/yt-dlp.exe";
    QString ytdlpSeed = QCoreApplication::applicationDirPath() + "/yt-dlp.exe";
    if (!QFileInfo::exists(ytdlpSeed)) ytdlpSeed = QStandardPaths::findExecutable("yt-dlp");
#else
    const QString ytdlp = QDir::homePath() + "/.local/share/melo/bin/yt-dlp";
    const QString ytdlpSeed = QStandardPaths::findExecutable("yt-dlp");   // seed from PATH if present
#endif

    // The silence scan's ffmpeg: beside the binary in an install or AppImage,
    // the vendored build in a dev tree, else empty and the sidecar uses PATH.
    QString ffmpeg = QCoreApplication::applicationDirPath() + QStringLiteral("/ffmpeg");
#ifdef MELO_DEV_FFMPEG
    if (!QFileInfo::exists(ffmpeg)) ffmpeg = QStringLiteral(MELO_DEV_FFMPEG);
#endif
    if (!QFileInfo(ffmpeg).isExecutable()) ffmpeg.clear();

    const bool dark = QGuiApplication::styleHints()->colorScheme() != Qt::ColorScheme::Light;

    QJsonObject params{
        {"dataDir", dataDir},
        {"musicDir", musicDir},
        {"ytdlpPath", ytdlp},
        {"ytdlpSeedPath", ytdlpSeed},
        {"ffmpegPath", ffmpeg},
        {"osPrefersDark", dark},
        {"appVersion", QCoreApplication::applicationVersion()},
    };
    auto* c = rpc_->call("initialize", params, 15000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        std::fprintf(stderr, "[melo] sidecar ready: %s\n",
                     QJsonDocument(r.toObject()).toJson(QJsonDocument::Compact).constData());
        ready_ = true;
        emit readyChanged();
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("initialize", m);
    });
}

void SidecarService::search(const QString& query, const QVariantMap& filters) {
    QJsonObject params{{"query", query}};
    if (!filters.isEmpty()) params["filters"] = QJsonObject::fromVariantMap(filters);
    auto* c = rpc_->call("yt/search", params);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        emit searchResults(o["results"].toArray(), o["playlists"].toArray(),
                           o["continuation"].toString(), false);
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("search", m);
    });
}

void SidecarService::searchMore(const QString& continuation) {
    auto* c = rpc_->call("yt/searchContinuation", {{"token", continuation}});
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        emit searchResults(o["results"].toArray(), o["playlists"].toArray(),
                           o["continuation"].toString(), true);
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("search", m);
    });
}

void SidecarService::rpc(const QString& method, const QVariantMap& params,
                         const QJSValue& callback, int timeoutMs) {
    auto* c = call(method, QJsonObject::fromVariantMap(params), timeoutMs);
    auto cb = std::make_shared<QJSValue>(callback);
    connect(c, &RpcCall::finished, this, [this, cb](const QJsonValue& r) {
        QJSEngine* e = qjsEngine(this);
        if (!e || !cb->isCallable()) return;
        cb->call({ e->toScriptValue(QVariantMap{
            {"ok", true}, {"result", r.toVariant()} }) });
    });
    connect(c, &RpcCall::failed, this, [this, cb](int, const QString& m) {
        QJSEngine* e = qjsEngine(this);
        if (!e || !cb->isCallable()) return;
        cb->call({ e->toScriptValue(QVariantMap{
            {"ok", false}, {"error", m} }) });
    });
}

void SidecarService::listPlugins() {
    auto* c = call("plugins/list", {}, 10000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        emit pluginsChanged(r.toObject().value("plugins").toArray());
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("plugins/list", m);
    });
}

void SidecarService::setPluginEnabled(const QString& id, bool on) {
    auto* c = call("plugins/setEnabled", QJsonObject{{"id", id}, {"on", on}}, 10000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        emit pluginsChanged(r.toObject().value("plugins").toArray());
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("plugins/setEnabled", m);
    });
}

void SidecarService::setPluginGrants(const QString& id, const QJsonObject& grants) {
    auto* c = call("plugins/setGrants",
                   QJsonObject{{"id", id}, {"grants", grants}}, 10000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        emit pluginsChanged(r.toObject().value("plugins").toArray());
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("plugins/setGrants", m);
    });
}

void SidecarService::rescanPlugins() {
    auto* c = call("plugins/rescan", QJsonObject{}, 10000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        emit pluginsChanged(r.toObject().value("plugins").toArray());
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        emit rpcFailed("plugins/rescan", m);
    });
}

void SidecarService::pluginSearch(const QString& sourceId, const QString& query,
                                  const QString& continuation) {
    const bool append = !continuation.isEmpty();
    QJsonObject params{{"sourceId", sourceId}, {"query", query}};
    if (append) params["continuation"] = continuation;
    auto* c = call("plugin/search", params, 10000);
    connect(c, &RpcCall::finished, this, [this, sourceId, append](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        emit pluginSearchResults(sourceId, o.value("tracks").toArray(),
                                 o.value("continuation").toString(), append);
    });
    connect(c, &RpcCall::failed, this, [this, sourceId](int, const QString&) {
        emit pluginSearchFailed(sourceId);
    });
}

void SidecarService::sendPlayerEvent(const QString& type, const QVariantMap& payload) {
    if (!ready()) return;
    call("player/event",
         QJsonObject{{"type", type}, {"payload", QJsonObject::fromVariantMap(payload)}},
         5000);   // result ignored
}
