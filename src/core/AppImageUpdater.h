#pragma once
#include "AppImageInfo.h"
#include "Zsync.h"
#include "ZsyncJob.h"

#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>
#include <functional>
#include <optional>

class QNetworkAccessManager;
class QNetworkReply;
class QNetworkRequest;
class QThread;

// A running AppImage keeps itself current: it asks GitHub for the release its
// update information names, compares that release's SHA-1 with its own, and
// on Update builds the new file beside itself with ZsyncJob. Restart swaps the
// files and starts the new one once melo has quit.
class AppImageUpdater : public QObject {
    Q_OBJECT
    // a running AppImage with update information; nothing else is ever checked
    Q_PROPERTY(bool supported READ supported CONSTANT)
    // "" | "available" | "downloading" | "ready" | "failed"
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString version READ version NOTIFY changed)
    Q_PROPERTY(QString notesUrl READ notesUrl NOTIFY changed)
    // the AppImage's folder is writable
    Q_PROPERTY(bool canUpdate READ canUpdate NOTIFY changed)
    Q_PROPERTY(qint64 fetched READ fetched NOTIFY progressChanged)
    Q_PROPERTY(qint64 total READ total NOTIFY progressChanged)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    // "download" | "damaged" | "write" | "replace"
    Q_PROPERTY(QString errorKind READ errorKind NOTIFY changed)
    Q_PROPERTY(QString errorDetail READ errorDetail NOTIFY changed)

public:
    // `appImage` is the running file; empty means not an AppImage
    explicit AppImageUpdater(const QString& appImage, QObject* parent = nullptr);
    ~AppImageUpdater() override;

    // the file $APPIMAGE resolves to, else empty
    static QString runningAppImage();
    // an update is one whose file differs from the running one
    static bool differs(const QByteArray& localSha1Hex, const QByteArray& remoteSha1Hex) {
        return !remoteSha1Hex.isEmpty() && localSha1Hex.toLower() != remoteSha1Hex.toLower();
    }
    // A numbered release (alpha-N.P, vX.Y.Z) is offered only above `current`;
    // a named channel (nightly) whenever its file differs.
    static bool offered(const QString& tag, const QString& current,
                        const QByteArray& localSha1Hex, const QByteArray& remoteSha1Hex);
    // the arguments the new AppImage starts with: melo's flags, never a file or URL
    static QStringList relaunchArgs(const QStringList& args);
    static constexpr qint64 kIntervalMs = 24 * 60 * 60 * 1000;
    // wall-clock: a suspended laptop still checks once a day
    static constexpr int kTickMs = 10 * 60 * 1000;
    static constexpr int kFirstCheckMs = 5000;
    static constexpr qint64 kMaxReleaseBytes = 4 << 20;
    // an update file on a filesystem without flock() is stale only after this long
    static constexpr qint64 kNoLockStaleMs = qint64(7) * 24 * 60 * 60 * 1000;

    bool supported() const { return info_.valid(); }
    QString state() const { return state_; }
    QString version() const { return version_; }
    QString notesUrl() const { return notesUrl_; }
    bool canUpdate() const;
    qint64 fetched() const { return fetched_; }
    qint64 total() const { return total_; }
    QString error() const { return error_; }
    QString errorKind() const { return errorKind_; }
    QString errorDetail() const { return errorDetail_; }
    const appimage::UpdateInfo& updateInfo() const { return info_; }
    QString stagedPath() const;

    // Settings → Check for updates: on checks at launch and every 24 h
    void setEnabled(bool on);
    // where the release is read from; the update information's by default
    void setApiUrl(const QUrl& url) { apiUrl_ = url; }
    // what Restart calls once the files are swapped; QCoreApplication::quit by default
    void setQuit(std::function<void()> quit) { quit_ = std::move(quit); }
    // MELO_VERSION by default
    void setCurrentVersion(const QString& v) { current_ = v; }
    // a request that moves no data for this long fails; 30 s by default
    void setTransferTimeout(int ms);

    Q_INVOKABLE void check();
    Q_INVOKABLE void update();
    Q_INVOKABLE void restart();
    // the failed step again: the download, or the swap
    Q_INVOKABLE void retry();

    // Restart swapped the files: main() starts the new AppImage after quitting
    bool relaunchPending() const { return relaunch_; }
    bool relaunch() const;

signals:
    void changed();
    void progressChanged();
    void checkDone();

private:
    void setState(const QString& s);
    void failWith(const QString& kind, const QString& detail);
    void onRelease(const QByteArray& json);
    void onControl(const QByteArray& bytes, const QUrl& from, const QString& tag,
                   const QString& name, const QString& html);
    void withLocalSha1(std::function<void(QByteArray)> then);
    void checkFailed(const QString& why);
    void removeStale();
    void dropStaged();
    void tick();
    QNetworkReply* get(const QNetworkRequest& req, qint64 cap);

    QString appImage_;
    appimage::UpdateInfo info_;
    QUrl apiUrl_;
    bool enabled_ = false;
    bool checking_ = false;
    QTimer tick_;
    qint64 lastCheckMs_ = 0;
    QString current_;
    int timeoutMs_ = 30000;
    QNetworkAccessManager* nam_ = nullptr;
    QByteArray localSha1_;
    std::optional<zsync::Control> control_;
    QUrl controlUrl_;
    QString state_, version_, notesUrl_, error_, errorKind_, errorDetail_;
    qint64 fetched_ = 0, total_ = 0;
    QPointer<ZsyncJob> job_;
    QThread* jobThread_ = nullptr;
    QList<QThread*> hashThreads_;
    // the update being built or waiting for Restart: a unique file beside the
    // AppImage, flock()ed while this melo holds it, and its identity once verified
    QString stagedPath_;
    int stagedFd_ = -1;
    bool staged_ = false;
    struct Ident { quint64 dev = 0, ino = 0; qint64 size = -1, mtimeNs = 0; } ident_;
    bool relaunch_ = false;
    std::function<void()> quit_;
};
