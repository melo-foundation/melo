#pragma once
#include <QObject>
#include <QJsonObject>
#include <QJsonArray>
#include <QJSValue>

class SidecarProcess;
class RpcClient;

// Typed facade over the RPC client. Owns initialize/re-initialize on (re)start.
class SidecarService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    explicit SidecarService(QObject* parent = nullptr);

    void start();
    bool ready() const { return ready_; }

    // Generic typed access for stores/coordinator (returns self-deleting RpcCall).
    class RpcCall* call(const QString& method, const QJsonObject& params = {}, int timeoutMs = 30000);

    // QML-callable; results via signals
    Q_INVOKABLE void search(const QString& query, const QVariantMap& filters = QVariantMap());
    Q_INVOKABLE void searchMore(const QString& continuation);
    // generic QML RPC: cb({ok, result}) or cb({ok:false, error}).
    // timeoutMs: batch jobs (metadata/batchEnrich does a network lookup per
    // track) outlive the 45s default.
    Q_INVOKABLE void rpc(const QString& method, const QVariantMap& params,
                         const QJSValue& callback, int timeoutMs = 45000);

    // Plugin surface
    Q_INVOKABLE void listPlugins();                                        // async -> pluginsChanged
    Q_INVOKABLE void setPluginEnabled(const QString& id, bool on);         // async -> pluginsChanged
    Q_INVOKABLE void setPluginGrants(const QString& id, const QJsonObject& grants);
    Q_INVOKABLE void rescanPlugins();                                      // async -> pluginsChanged
    Q_INVOKABLE void pluginSearch(const QString& sourceId, const QString& query,
                                  const QString& continuation = QString());
    void sendPlayerEvent(const QString& type, const QVariantMap& payload); // fire-and-forget

signals:
    void readyChanged();
    void searchResults(const QJsonArray& results, const QJsonArray& playlists,
                       const QString& continuation, bool append);
    void rpcFailed(const QString& what, const QString& message);
    void nodeMissing();
    void libraryChanged();
    void jobDone(const QString& jobId, bool ok, const QJsonObject& result);
    void pluginsChanged(const QJsonArray& plugins);
    // extraction failed in a way that a newer yt-dlp usually fixes; the UI
    // offers the nightly channel rather than switching silently
    void ytdlpStale(const QString& message);
    void pluginSearchResults(const QString& sourceId, const QJsonArray& tracks,
                             const QString& continuation, bool append);
    void pluginSearchFailed(const QString& sourceId);

private:
    void initialize();

    SidecarProcess* proc_;
    RpcClient* rpc_;
    bool ready_ = false;
};
