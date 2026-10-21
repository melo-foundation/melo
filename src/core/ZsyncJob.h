#pragma once
#include "Zsync.h"

#include <QFile>
#include <QObject>
#include <QUrl>
#include <atomic>
#include <memory>
#include <vector>

class QNetworkAccessManager;
class QNetworkReply;

// Builds the new file next to the old one: the blocks the old file already has,
// then the rest over HTTP Range requests, then the SHA-1. Run it on a thread of
// its own; every signal is queued to the caller. Nothing is left behind on a
// failure.
class ZsyncJob : public QObject {
    Q_OBJECT
public:
    enum Failure { Network, Damaged, Write, Cancelled };
    Q_ENUM(Failure)

    // `controlUrl` resolves the control file's own URL line; `outPath` is
    // created, and must sit on the same filesystem as the file it replaces.
    ZsyncJob(zsync::Control control, QUrl controlUrl, QString source, QString outPath,
             QObject* parent = nullptr);
    ~ZsyncJob() override;

    // From any thread.
    void cancel() { cancelled_ = true; }
    // a request that moves no data for this long fails as Network; before start()
    void setTransferTimeout(int ms) { timeoutMs_ = ms; }

    // ranges whose gap is at most this many known blocks go in one request
    static constexpr qint64 kMergeGap = 32;
    static constexpr qint64 kMaxRequestBytes = 8 << 20;
    static constexpr int kParallel = 4;

public slots:
    void start();

signals:
    void scanned(qint64 haveBlocks, qint64 blocks);
    void progress(qint64 fetched, qint64 total);
    void finished(const QString& path, qint64 fetched);
    void failed(ZsyncJob::Failure why, const QString& detail);

private:
    struct Fetch {
        QNetworkReply* reply = nullptr;
        qint64 first = 0, last = 0, next = 0;
        QByteArray buf;
        qint64 received = 0;
        bool checked = false;
    };
    void pump();
    void onData(Fetch* f);
    void onDone(Fetch* f);
    void startWhole(QNetworkReply* r);
    void wholeData();
    void wholeDone();
    void begin();
    void finish();
    void fail(Failure why, const QString& detail);

    zsync::Control c_;
    QUrl url_;
    QString source_, outPath_;
    QFile out_;
    std::vector<char> have_;
    std::vector<std::pair<qint64, qint64>> queue_;
    std::vector<std::unique_ptr<Fetch>> active_;
    QNetworkAccessManager* nam_ = nullptr;
    QNetworkReply* whole_ = nullptr;
    qint64 fetched_ = 0, total_ = 0, wholeAt_ = 0;
    qint64 lastProgressMs_ = 0;
    bool done_ = false;
    int timeoutMs_ = 30000;
    std::atomic<bool> cancelled_ { false };
};
