#pragma once

// Thumbnails decoded once and cached per (url, requested size).
//
// Qt caps unreferenced pixmaps at a hardcoded 2MB (file-static in
// qquickpixmap.cpp), about seven card thumbnails, so a scrolled feed decoded
// each image 3.7 times; holding an Image from QML does not keep the pixmap.
// Only the decode is cached here; the bytes still come from the network cache.

#include <QByteArray>
#include <QHash>
#include <QImage>
#include <QList>
#include <QMutex>
#include <QQuickAsyncImageProvider>
#include <QSize>
#include <QString>

class QNetworkAccessManager;

class ThumbImageProvider : public QQuickAsyncImageProvider {
public:
    // "thumb": source is image://thumb/<percent-encoded http url>
    static constexpr const char* kProviderId = "thumb";

    explicit ThumbImageProvider(QString cacheDir, qint64 budgetBytes = 96LL * 1024 * 1024);
    ~ThumbImageProvider() override;

    QQuickImageResponse* requestImageResponse(const QString& id,
                                              const QSize& requestedSize) override;

    // The decoded frame for this exact (url, requested size), or a null image.
    QImage take(const QString& key) const;
    void put(const QString& key, const QImage& img);
    // for the smoke test and for logging
    struct Stats { qint64 hits = 0; qint64 misses = 0; qint64 bytes = 0; int entries = 0; };
    Stats stats() const;

    QNetworkAccessManager* nam();

private:
    void trim();

    QString cacheDir_;
    qint64 budget_;
    mutable QMutex mutex_;
    QHash<QString, QImage> cache_;
    QList<QString> lru_;          // front = most recently used
    qint64 bytes_ = 0;
    mutable qint64 hits_ = 0;
    mutable qint64 misses_ = 0;
    QNetworkAccessManager* nam_ = nullptr;
};
