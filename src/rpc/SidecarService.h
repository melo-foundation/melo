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
    // "downloading" while the first-run yt-dlp download runs, "failed" if it
    // did not complete, empty otherwise
    Q_PROPERTY(QString ytdlpState READ ytdlpState NOTIFY ytdlpStateChanged)
    // bytes of that download so far; total is 0 until the size is known
    Q_PROPERTY(qint64 ytdlpReceived READ ytdlpReceived NOTIFY ytdlpProgressChanged)
    Q_PROPERTY(qint64 ytdlpTotal READ ytdlpTotal NOTIFY ytdlpProgressChanged)
public:
    explicit SidecarService(QObject* parent = nullptr);

    void start();
    bool ready() const { return ready_; }
    QString ytdlpState() const { return ytdlpState_; }
    qint64 ytdlpReceived() const { return ytdlpReceived_; }
    qint64 ytdlpTotal() const { return ytdlpTotal_; }

    // RPC timeout for a call that may need yt-dlp: normalMs, or long enough to
    // outlast the first-run download while one is running (300 s + SUMS fetch).
    int ytdlpTimeoutMs(int normalMs) const;

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
    void ytdlpStateChanged();
    void ytdlpProgressChanged();
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
    void setYtdlpStatus(const QString& state, qint64 received, qint64 total);

    QString ytdlpState_;
    qint64 ytdlpReceived_ = 0;
    qint64 ytdlpTotal_ = 0;
};
