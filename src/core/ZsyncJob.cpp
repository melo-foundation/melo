#include "ZsyncJob.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <algorithm>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <unistd.h>

ZsyncJob::ZsyncJob(zsync::Control control, QUrl controlUrl, QString source, QString outPath,
                   QObject* parent)
    : QObject(parent), c_(std::move(control)), source_(std::move(source)), outPath_(std::move(outPath)) {
    url_ = controlUrl.resolved(QUrl(c_.url));
}

ZsyncJob::~ZsyncJob() {
    if (!done_) {
        for (auto& f : active_) if (f->reply) f->reply->abort();
        if (whole_) whole_->abort();
        out_.close();
        QFile::remove(outPath_);
    }
}

void ZsyncJob::fail(Failure why, const QString& detail) {
    if (done_) return;
    done_ = true;
    for (auto& f : active_) if (f->reply) { f->reply->disconnect(this); f->reply->abort(); }
    if (whole_) { whole_->disconnect(this); whole_->abort(); }
    out_.close();
    QFile::remove(outPath_);
    emit failed(why, detail);
}

// no exception leaves a slot: a failed allocation fails the job
void ZsyncJob::start() {
    try {
        begin();
    } catch (const std::exception& e) {
        fail(Write, QString::fromLocal8Bit(e.what()));
    }
}

void ZsyncJob::begin() {
    out_.setFileName(outPath_);
    if (!out_.open(QIODevice::ReadWrite | QIODevice::Truncate) || !out_.resize(c_.length))
        return fail(Write, out_.errorString());
    QString err;
    if (!zsync::scan(c_, source_, out_, have_, &cancelled_, &err))
        return fail(cancelled_ ? Cancelled : Write, err);
    qint64 got = 0;
    for (char h : have_) got += h;
    emit scanned(got, c_.blockCount());

    // the missing blocks, merged across small gaps and split to a bounded size
    const qint64 maxBlocks = qMax<qint64>(1, kMaxRequestBytes / c_.blocksize);
    for (auto [a, b] : zsync::missingRanges(have_, kMergeGap)) {
        for (qint64 s = a; s <= b; s += maxBlocks) {
            const qint64 e = qMin(b, s + maxBlocks - 1);
            queue_.emplace_back(s, e);
            total_ += qMin(c_.length, c_.blockStart(e + 1)) - c_.blockStart(s);
        }
    }
    std::reverse(queue_.begin(), queue_.end());   // popped from the back, in file order
    emit progress(0, total_);
    nam_ = new QNetworkAccessManager(this);
    nam_->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
    nam_->setTransferTimeout(timeoutMs_);
    pump();
}

void ZsyncJob::pump() {
    if (done_ || whole_) return;
    if (cancelled_) return fail(Cancelled, QStringLiteral("cancelled"));
    while (int(active_.size()) < kParallel && !queue_.empty()) {
        auto [a, b] = queue_.back();
        queue_.pop_back();
        auto f = std::make_unique<Fetch>();
        f->first = a; f->last = b; f->next = a;
        QNetworkRequest req(url_);
        const qint64 from = c_.blockStart(a), to = qMin(c_.length, c_.blockStart(b + 1)) - 1;
        req.setRawHeader("Range", QByteArray("bytes=") + QByteArray::number(from) + '-' + QByteArray::number(to));
        req.setHeader(QNetworkRequest::UserAgentHeader, QByteArrayLiteral("melo"));
        f->reply = nam_->get(req);
        Fetch* raw = f.get();
        connect(f->reply, &QNetworkReply::readyRead, this, [this, raw] { onData(raw); });
        connect(f->reply, &QNetworkReply::finished, this, [this, raw] { onDone(raw); });
        active_.push_back(std::move(f));
    }
    if (active_.empty() && queue_.empty()) finish();
}

void ZsyncJob::onData(Fetch* f) {
    if (done_) return;
    if (!f->checked) {
        const int status = f->reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 200) return startWhole(f->reply);   // the server ignores Range: take the file whole
        if (status != 206) return fail(Network, QStringLiteral("HTTP %1").arg(status));
        static const QRegularExpression cr(QStringLiteral("^bytes (\\d+)-"));
        const auto m = cr.match(QString::fromLatin1(f->reply->rawHeader("Content-Range")));
        if (!m.hasMatch() || m.captured(1).toLongLong() != c_.blockStart(f->first))
            return fail(Network, QStringLiteral("unexpected Content-Range ") + QString::fromLatin1(f->reply->rawHeader("Content-Range")));
        f->checked = true;
    }
    const QByteArray chunk = f->reply->readAll();
    f->received += chunk.size();
    // never more than was asked for
    if (f->received > qMin(c_.length, c_.blockStart(f->last + 1)) - c_.blockStart(f->first))
        return fail(Network, QStringLiteral("response longer than its range"));
    f->buf += chunk;
    fetched_ += chunk.size();
    QByteArray block;
    qsizetype used = 0;
    while (f->next <= f->last) {
        const qint64 len = c_.blockLen(f->next);
        if (f->buf.size() - used < len) break;
        if (!have_[size_t(f->next)]) {
            block = f->buf.mid(used, len);
            if (len < c_.blocksize) block.append(QByteArray(c_.blocksize - len, '\0'));
            if (!c_.strongMatches(f->next, reinterpret_cast<const uchar*>(block.constData())))
                return fail(Damaged, QStringLiteral("block %1 does not match").arg(f->next));
            if (!out_.seek(c_.blockStart(f->next)) || out_.write(f->buf.constData() + used, len) != len)
                return fail(Write, out_.errorString());
            have_[size_t(f->next)] = 1;
        }
        used += len;
        ++f->next;
    }
    f->buf.remove(0, used);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - lastProgressMs_ >= 100) { lastProgressMs_ = now; emit progress(fetched_, total_); }
}

void ZsyncJob::onDone(Fetch* f) {
    if (done_ || whole_) return;
    QNetworkReply* r = f->reply;
    if (r->error() != QNetworkReply::NoError) return fail(Network, r->errorString());
    onData(f);
    if (done_ || whole_) return;
    if (f->next <= f->last) return fail(Network, QStringLiteral("response ended early"));
    r->deleteLater();
    active_.erase(std::remove_if(active_.begin(), active_.end(),
                                 [f](const std::unique_ptr<Fetch>& p) { return p.get() == f; }),
                  active_.end());
    pump();
}

void ZsyncJob::startWhole(QNetworkReply* r) {
    std::fprintf(stderr, "[update] server ignores Range, downloading the whole file\n");
    r->disconnect(this);
    for (auto& f : active_)
        if (f->reply && f->reply != r) { f->reply->disconnect(this); f->reply->abort(); f->reply->deleteLater(); }
    active_.clear();
    queue_.clear();
    total_ = c_.length;
    fetched_ = 0;
    whole_ = r;
    connect(whole_, &QNetworkReply::readyRead, this, &ZsyncJob::wholeData);
    connect(whole_, &QNetworkReply::finished, this, &ZsyncJob::wholeDone);
    // the reply may be over already: its finished signal is the one being handled
    if (whole_->isFinished()) QMetaObject::invokeMethod(this, &ZsyncJob::wholeDone, Qt::QueuedConnection);
    else QMetaObject::invokeMethod(this, &ZsyncJob::wholeData, Qt::QueuedConnection);
}

void ZsyncJob::wholeData() {
    if (done_) return;
    const QByteArray chunk = whole_->readAll();
    if (wholeAt_ + chunk.size() > c_.length) return fail(Network, QStringLiteral("file longer than its Length"));
    if (!chunk.isEmpty() && (!out_.seek(wholeAt_) || out_.write(chunk) != chunk.size()))
        return fail(Write, out_.errorString());
    wholeAt_ += chunk.size();
    fetched_ = wholeAt_;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - lastProgressMs_ >= 100) { lastProgressMs_ = now; emit progress(fetched_, total_); }
}

void ZsyncJob::wholeDone() {
    if (done_) return;
    if (whole_->error() != QNetworkReply::NoError) return fail(Network, whole_->errorString());
    wholeData();
    if (done_) return;
    if (wholeAt_ != c_.length) return fail(Network, QStringLiteral("got %1 of %2 bytes").arg(wholeAt_).arg(c_.length));
    finish();
}

void ZsyncJob::finish() {
    if (done_) return;
    emit progress(fetched_, total_);
    if (!out_.resize(c_.length) || !out_.flush()) return fail(Write, out_.errorString());
    if (!out_.seek(0)) return fail(Write, out_.errorString());
    QCryptographicHash sha(QCryptographicHash::Sha1);
    if (!sha.addData(&out_)) return fail(Write, out_.errorString());
    const QByteArray got = sha.result().toHex();
    if (got != c_.sha1)
        return fail(Damaged, QStringLiteral("SHA-1 %1, expected %2").arg(QString::fromLatin1(got), QString::fromLatin1(c_.sha1)));
    // on disk before anything renames it, and run the way the old one was
    if (::fsync(int(out_.handle())) != 0) return fail(Write, QString::fromLocal8Bit(std::strerror(errno)));
    if (!out_.setPermissions(QFileInfo(source_).permissions())) return fail(Write, out_.errorString());
    out_.close();
    done_ = true;
    emit finished(outPath_, fetched_);
}
