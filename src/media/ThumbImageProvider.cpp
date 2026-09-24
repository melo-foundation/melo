#include "ThumbImageProvider.h"

#include <QBuffer>
#include <QImageReader>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQuickImageResponse>
#include <QUrl>

namespace {

QString keyFor(const QString& url, const QSize& req) {
    return url + QLatin1Char('|') + QString::number(req.width())
         + QLatin1Char('x') + QString::number(req.height());
}

qint64 costOf(const QImage& img) {
    return static_cast<qint64>(img.sizeInBytes());
}

// One request. A cache hit finishes before the engine ever looks at it; a miss
// fetches, decodes at the asked-for size, and hands the frame to the cache.
class ThumbResponse : public QQuickImageResponse {
    Q_OBJECT
public:
    ThumbResponse(ThumbImageProvider* owner, QString url, QSize requested)
        : owner_(owner), url_(std::move(url)), requested_(requested) {
        const QImage hit = owner_->take(keyFor(url_, requested_));
        if (!hit.isNull()) {
            image_ = hit;
            // Queued: the engine connects to finished() after this constructor
            // returns, so emitting here would reach no one.
            QMetaObject::invokeMethod(this, "settle", Qt::QueuedConnection);
            return;
        }
        QNetworkRequest req{QUrl(url_)};
        req.setAttribute(QNetworkRequest::CacheLoadControlAttribute,
                         QNetworkRequest::PreferCache);
        req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
        reply_ = owner_->nam()->get(req);
        QObject::connect(reply_, &QNetworkReply::finished, this, &ThumbResponse::onReply);
    }

    QQuickTextureFactory* textureFactory() const override {
        return QQuickTextureFactory::textureFactoryForImage(image_);
    }
    QString errorString() const override { return error_; }

public slots:
    void settle() { emit finished(); }

private:
    void onReply() {
        reply_->deleteLater();
        if (reply_->error() != QNetworkReply::NoError) {
            error_ = reply_->errorString();
            emit finished();
            return;
        }
        const QByteArray bytes = reply_->readAll();
        QBuffer buf;
        buf.setData(bytes);
        buf.open(QIODevice::ReadOnly);
        QImageReader reader(&buf);
        reader.setAutoTransform(true);
        // Scaled by the reader where the format can do it: libjpeg scales
        // during decode, libwebp cannot and decodes whole then resizes. Asking
        // the reader either way keeps this the same picture Image would make.
        if (requested_.width() > 0 || requested_.height() > 0) {
            const QSize full = reader.size();
            if (full.isValid() && !full.isEmpty()) {
                QSize want = full;
                want.scale(requested_.width() > 0 ? requested_.width() : full.width(),
                           requested_.height() > 0 ? requested_.height() : full.height(),
                           Qt::KeepAspectRatio);
                reader.setScaledSize(want);
            }
        }
        QImage img = reader.read();
        if (img.isNull()) {
            error_ = reader.errorString();
            emit finished();
            return;
        }
        image_ = img;
        owner_->put(keyFor(url_, requested_), img);
        emit finished();
    }

    ThumbImageProvider* owner_;
    QString url_;
    QSize requested_;
    QImage image_;
    QString error_;
    QNetworkReply* reply_ = nullptr;
};

}  // namespace

ThumbImageProvider::ThumbImageProvider(QString cacheDir, qint64 budgetBytes)
    : cacheDir_(std::move(cacheDir)), budget_(budgetBytes) {}

ThumbImageProvider::~ThumbImageProvider() = default;

QNetworkAccessManager* ThumbImageProvider::nam() {
    if (!nam_) {
        nam_ = new QNetworkAccessManager;
        // The engine's disk cache directory, so a picture already fetched is
        // not fetched again.
        auto* disk = new QNetworkDiskCache(nam_);
        disk->setCacheDirectory(cacheDir_);
        disk->setMaximumCacheSize(512LL * 1024 * 1024);
        nam_->setCache(disk);
    }
    return nam_;
}

QImage ThumbImageProvider::take(const QString& key) const {
    QMutexLocker lock(&mutex_);
    const auto it = cache_.constFind(key);
    if (it == cache_.cend()) { ++misses_; return {}; }
    ++hits_;
    auto* self = const_cast<ThumbImageProvider*>(this);
    self->lru_.removeOne(key);
    self->lru_.prepend(key);
    return it.value();
}

void ThumbImageProvider::put(const QString& key, const QImage& img) {
    if (img.isNull()) return;
    QMutexLocker lock(&mutex_);
    if (cache_.contains(key)) {
        bytes_ -= costOf(cache_.value(key));
        lru_.removeOne(key);
    }
    cache_.insert(key, img);
    lru_.prepend(key);
    bytes_ += costOf(img);
    trim();
}

void ThumbImageProvider::trim() {
    while (bytes_ > budget_ && !lru_.isEmpty()) {
        const QString oldest = lru_.takeLast();
        bytes_ -= costOf(cache_.value(oldest));
        cache_.remove(oldest);
    }
}

ThumbImageProvider::Stats ThumbImageProvider::stats() const {
    QMutexLocker lock(&mutex_);
    return Stats{hits_, misses_, bytes_, static_cast<int>(cache_.size())};
}

QQuickImageResponse* ThumbImageProvider::requestImageResponse(const QString& id,
                                                              const QSize& requestedSize) {
    // The id is the url, percent-decoded by the engine before it lands here.
    return new ThumbResponse(this, id, requestedSize);
}

#include "ThumbImageProvider.moc"
