#include "AppImageUpdater.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QThread>
#include <QDateTime>
#include <QRegularExpression>
#include <QVersionNumber>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
void logLine(const QString& s) { std::fprintf(stderr, "[update] %s\n", qPrintable(s)); }

// 0.N.P from alpha-N(.P), X.Y.Z from vX.Y.Z; null for a named channel
QVersionNumber tagVersion(const QString& tag) {
    static const QRegularExpression alpha(QStringLiteral("^alpha-(\\d+)(?:\\.(\\d+))?$"));
    static const QRegularExpression semver(QStringLiteral("^v?(\\d+(?:\\.\\d+){1,2})$"));
    if (const auto m = alpha.match(tag); m.hasMatch())
        return QVersionNumber(0, m.captured(1).toInt(), m.captured(2).toInt());
    if (const auto m = semver.match(tag); m.hasMatch()) return QVersionNumber::fromString(m.captured(1));
    return {};
}

bool identOf(int fd, quint64* dev, quint64* ino, qint64* size, qint64* mtimeNs) {
    struct stat st {};
    if (fd < 0 || ::fstat(fd, &st) != 0) return false;
    *dev = st.st_dev; *ino = st.st_ino; *size = st.st_size;
    *mtimeNs = qint64(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec;
    return true;
}
bool identOfPath(const QString& path, quint64* dev, quint64* ino) {
    struct stat st {};
    if (::stat(QFile::encodeName(path).constData(), &st) != 0) return false;
    *dev = st.st_dev; *ino = st.st_ino;
    return true;
}
}

bool AppImageUpdater::offered(const QString& tag, const QString& current,
                              const QByteArray& localSha1Hex, const QByteArray& remoteSha1Hex) {
    if (!differs(localSha1Hex, remoteSha1Hex)) return false;
    const QVersionNumber t = tagVersion(tag), c = QVersionNumber::fromString(current);
    return t.isNull() || c.isNull() || t > c;
}

QStringList AppImageUpdater::relaunchArgs(const QStringList& args) {
    QStringList out;
    for (const QString& a : args)
        if (a.startsWith(u'-')) out << a;
    return out;
}

AppImageUpdater::AppImageUpdater(const QString& appImage, QObject* parent)
    : QObject(parent), appImage_(appImage) {
    if (!appImage_.isEmpty()) info_ = appimage::parseUpdateInfo(appimage::elfSection(appImage_, ".upd_info"));
    if (!supported()) return;
    apiUrl_ = QUrl(info_.apiUrl());
    nam_ = new QNetworkAccessManager(this);
    nam_->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
    nam_->setTransferTimeout(timeoutMs_);
    current_ = QCoreApplication::applicationVersion();
    tick_.setInterval(kTickMs);
    connect(&tick_, &QTimer::timeout, this, &AppImageUpdater::tick);
    removeStale();
}

AppImageUpdater::~AppImageUpdater() {
    if (job_) job_->cancel();
    if (jobThread_) { jobThread_->quit(); jobThread_->wait(); }
    for (QThread* t : hashThreads_) t->wait();
    if (!relaunch_) dropStaged();
}

QString AppImageUpdater::runningAppImage() {
    const QString p = qEnvironmentVariable("APPIMAGE");
    if (p.isEmpty() || !QFileInfo(p).isFile()) return {};
    // the file itself: a symlink to it stays a symlink after Restart
    return QFileInfo(p).canonicalFilePath();
}

QString AppImageUpdater::stagedPath() const { return stagedPath_; }

void AppImageUpdater::setTransferTimeout(int ms) {
    timeoutMs_ = ms;
    if (nam_) nam_->setTransferTimeout(ms);
}

// Updates other melos left behind: any not locked by a live process.
void AppImageUpdater::removeStale() {
    const QFileInfo fi(appImage_);
    QDir dir(fi.absolutePath());
    const QStringList left = dir.entryList({ QStringLiteral(".") + fi.fileName() + QStringLiteral(".update-*") },
                                           QDir::Files | QDir::Hidden);
    for (const QString& n : left) {
        const QByteArray path = QFile::encodeName(dir.filePath(n));
        const int fd = ::open(path.constData(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        // unlockable where it was made: its age is the only sign it is abandoned
        const bool noLock = n.contains(QStringLiteral(".update-nolock-"));
        const bool old = QDateTime::currentMSecsSinceEpoch()
                         - QFileInfo(dir.filePath(n)).lastModified().toMSecsSinceEpoch() >= kNoLockStaleMs;
        if (::flock(fd, LOCK_EX | LOCK_NB) == 0 && (!noLock || old)) {
            ::unlink(path.constData());
            logLine(QStringLiteral("removed a stale ") + dir.filePath(n));
        }
        ::close(fd);
    }
}

// Removes this melo's update file, and only while the path is still that file.
void AppImageUpdater::dropStaged() {
    staged_ = false;
    if (stagedFd_ < 0) return;
    quint64 dev = 0, ino = 0, pdev = 0, pino = 0;
    qint64 size = 0, mt = 0;
    if (identOf(stagedFd_, &dev, &ino, &size, &mt) && identOfPath(stagedPath_, &pdev, &pino)
            && dev == pdev && ino == pino)
        QFile::remove(stagedPath_);
    ::close(stagedFd_);
    stagedFd_ = -1;
}

void AppImageUpdater::tick() {
    // the clock was set back: count from now
    if (lastCheckMs_ > QDateTime::currentMSecsSinceEpoch()) lastCheckMs_ = QDateTime::currentMSecsSinceEpoch() - kIntervalMs;
    if (enabled_ && QDateTime::currentMSecsSinceEpoch() - lastCheckMs_ >= kIntervalMs) check();
}

QNetworkReply* AppImageUpdater::get(const QNetworkRequest& req, qint64 cap) {
    QNetworkReply* r = nam_->get(req);
    connect(r, &QNetworkReply::downloadProgress, r, [r, cap](qint64 got, qint64) { if (got > cap) r->abort(); });
    return r;
}

bool AppImageUpdater::canUpdate() const {
    return supported() && ::access(QFile::encodeName(QFileInfo(appImage_).absolutePath()).constData(), W_OK) == 0;
}

void AppImageUpdater::setState(const QString& s) {
    if (state_ == s) return;
    state_ = s;
    emit changed();
}

void AppImageUpdater::setEnabled(bool on) {
    if (!supported() || enabled_ == on) return;
    enabled_ = on;
    if (!on) {
        tick_.stop();
        if (state_ == QLatin1String("available")) setState({});
        return;
    }
    tick_.start();
    QTimer::singleShot(kFirstCheckMs, this, [this] { if (enabled_) check(); });
}

void AppImageUpdater::checkFailed(const QString& why) {
    checking_ = false;
    logLine(QStringLiteral("check failed: ") + why);
    emit checkDone();
}

void AppImageUpdater::check() {
    if (!supported() || checking_) return;
    // a download in flight or one waiting for Restart is not checked over
    if (state_ == QLatin1String("downloading") || state_ == QLatin1String("ready")) return;
    checking_ = true;
    lastCheckMs_ = QDateTime::currentMSecsSinceEpoch();
    logLine(QStringLiteral("checking ") + apiUrl_.toString());
    QNetworkRequest req(apiUrl_);
    req.setRawHeader("Accept", "application/vnd.github+json");
    req.setHeader(QNetworkRequest::UserAgentHeader, QByteArray("melo/") + QCoreApplication::applicationVersion().toUtf8());
    QNetworkReply* r = get(req, kMaxReleaseBytes);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) return checkFailed(r->errorString());
        onRelease(r->readAll());
    });
}

void AppImageUpdater::onRelease(const QByteArray& json) {
    const QJsonObject rel = QJsonDocument::fromJson(json).object();
    const QString tag = rel.value("tag_name").toString();
    if (tag.isEmpty()) return checkFailed(QStringLiteral("no release in the answer"));
    QUrl zsyncUrl;
    for (const QJsonValue& v : rel.value("assets").toArray()) {
        const QJsonObject a = v.toObject();
        if (info_.matchesAsset(a.value("name").toString())) {
            zsyncUrl = QUrl(a.value("browser_download_url").toString());
            break;
        }
    }
    if (!zsyncUrl.isValid() || zsyncUrl.isEmpty())
        return checkFailed(QStringLiteral("release %1 has no %2").arg(tag, info_.zsyncName));
    const QString name = rel.value("name").toString(), html = rel.value("html_url").toString();
    QNetworkRequest req(zsyncUrl);
    req.setHeader(QNetworkRequest::UserAgentHeader, QByteArrayLiteral("melo"));
    QNetworkReply* r = get(req, zsync::kMaxControlBytes);
    connect(r, &QNetworkReply::finished, this, [=] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) return checkFailed(r->errorString());
        // the control file's URL line is relative to where it was asked for, not to the redirect
        onControl(r->readAll(), zsyncUrl, tag, name, html);
    });
}

void AppImageUpdater::withLocalSha1(std::function<void(QByteArray)> then) {
    if (!localSha1_.isEmpty()) return then(localSha1_);
    auto out = std::make_shared<QByteArray>();
    const QString path = appImage_;
    QThread* t = QThread::create([out, path] {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) return;
        QCryptographicHash h(QCryptographicHash::Sha1);
        if (h.addData(&f)) *out = h.result().toHex();
    });
    hashThreads_ << t;
    connect(t, &QThread::finished, this, [this, t, out, then] {
        hashThreads_.removeOne(t);
        t->deleteLater();
        localSha1_ = *out;
        then(localSha1_);
    });
    t->start(QThread::LowPriority);
}

void AppImageUpdater::onControl(const QByteArray& bytes, const QUrl& from, const QString& tag,
                                const QString& name, const QString& html) {
    QString err;
    std::optional<zsync::Control> c = zsync::parse(bytes, &err);
    if (!c) return checkFailed(from.toString() + QStringLiteral(": ") + err);
    withLocalSha1([=](QByteArray local) mutable {
        checking_ = false;
        if (local.isEmpty()) return checkFailed(QStringLiteral("could not read ") + appImage_);
        const bool newer = offered(tag, current_, local, c->sha1);
        logLine(QStringLiteral("%1 %2: %3").arg(tag, QString::fromLatin1(c->sha1),
                newer ? QStringLiteral("differs from the running %1").arg(QString::fromLatin1(local))
                : !differs(local, c->sha1) ? QStringLiteral("is the running AppImage")
                : QStringLiteral("is not newer than %1").arg(current_)));
        if (newer && state_ != QLatin1String("downloading") && state_ != QLatin1String("ready")) {
            control_ = std::move(c);
            controlUrl_ = from;
            version_ = appimage::versionLabel(tag, name);
            notesUrl_ = html;
            error_.clear(); errorKind_.clear(); errorDetail_.clear();
            if (state_ != QLatin1String("available")) state_ = QStringLiteral("available");
            emit changed();
        } else if (!newer && state_ == QLatin1String("available")) {
            setState({});
        }
        emit checkDone();
    });
}

void AppImageUpdater::failWith(const QString& kind, const QString& detail) {
    errorKind_ = kind;
    errorDetail_ = detail;
    if (kind == QLatin1String("download"))
        error_ = QStringLiteral("The update could not be downloaded. Check your connection and retry.");
    else if (kind == QLatin1String("damaged"))
        error_ = QStringLiteral("The downloaded update is damaged. Retry to download it again.");
    else if (kind == QLatin1String("write"))
        error_ = QStringLiteral("The update could not be written next to melo's AppImage. Check that folder's free space and permissions, then retry.");
    else
        error_ = QStringLiteral("melo's AppImage could not be replaced. Check its folder's permissions and retry.");
    logLine(QStringLiteral("failed (%1): %2").arg(kind, detail));
    state_ = QStringLiteral("failed");
    emit changed();
}

void AppImageUpdater::update() {
    if (!control_ || !canUpdate() || job_) return;
    if (state_ != QLatin1String("available") && !(state_ == QLatin1String("failed") && errorKind_ != QLatin1String("replace")))
        return;
    dropStaged();
    // a name of its own, so two melos on one AppImage never share a file
    const QFileInfo fi(appImage_);
    QByteArray tmpl = QFile::encodeName(fi.absolutePath() + QStringLiteral("/.") + fi.fileName()
                                        + QStringLiteral(".update-XXXXXX"));
    int fd = ::mkostemp(tmpl.data(), O_CLOEXEC);
    if (fd < 0) return failWith(QStringLiteral("write"), QString::fromLocal8Bit(std::strerror(errno)));
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        // no locks here: a name other melos leave alone until it is a week old
        logLine(QStringLiteral("no lock on %1: %2").arg(QFile::decodeName(tmpl), QString::fromLocal8Bit(std::strerror(errno))));
        QByteArray marked = QFile::encodeName(fi.absolutePath() + QStringLiteral("/.") + fi.fileName()
                                              + QStringLiteral(".update-nolock-XXXXXX"));
        const int fd2 = ::mkostemp(marked.data(), O_CLOEXEC);
        ::unlink(tmpl.constData());
        ::close(fd);
        if (fd2 < 0) return failWith(QStringLiteral("write"), QString::fromLocal8Bit(std::strerror(errno)));
        fd = fd2;
        tmpl = marked;
    }
    stagedFd_ = fd;
    stagedPath_ = QFile::decodeName(tmpl);
    error_.clear(); errorKind_.clear(); errorDetail_.clear();
    fetched_ = 0; total_ = 0;
    emit progressChanged();
    setState(QStringLiteral("downloading"));
    logLine(QStringLiteral("downloading %1 from %2").arg(version_, controlUrl_.resolved(QUrl(control_->url)).toString()));

    jobThread_ = new QThread(this);
    auto* job = new ZsyncJob(*control_, controlUrl_, appImage_, stagedPath_);
    job->setTransferTimeout(timeoutMs_);
    job->moveToThread(jobThread_);
    job_ = job;
    connect(jobThread_, &QThread::started, job, &ZsyncJob::start);
    connect(jobThread_, &QThread::finished, job, &QObject::deleteLater);
    auto done = [this] {
        QThread* t = jobThread_;
        jobThread_ = nullptr;
        job_ = nullptr;
        connect(t, &QThread::finished, t, &QObject::deleteLater);
        t->quit();
    };
    connect(job, &ZsyncJob::scanned, this, [this](qint64 got, qint64 n) {
        logLine(QStringLiteral("local file has %1 of %2 blocks").arg(got).arg(n));
    });
    connect(job, &ZsyncJob::progress, this, [this](qint64 got, qint64 total) {
        fetched_ = got; total_ = total;
        emit progressChanged();
    });
    connect(job, &ZsyncJob::finished, this, [this, done](const QString& path, qint64 fetched) {
        done();
        if (!identOf(stagedFd_, &ident_.dev, &ident_.ino, &ident_.size, &ident_.mtimeNs)) {
            dropStaged();
            return failWith(QStringLiteral("write"), QString::fromLocal8Bit(std::strerror(errno)));
        }
        staged_ = true;
        logLine(QStringLiteral("verified %1 (SHA-1 %2), fetched %3 of %4 bytes")
                    .arg(path, QString::fromLatin1(control_->sha1)).arg(fetched).arg(control_->length));
        setState(QStringLiteral("ready"));
    });
    connect(job, &ZsyncJob::failed, this, [this, done](ZsyncJob::Failure why, const QString& detail) {
        done();
        ::close(stagedFd_);   // the job removed the file
        stagedFd_ = -1;
        failWith(why == ZsyncJob::Network ? QStringLiteral("download")
                 : why == ZsyncJob::Damaged ? QStringLiteral("damaged") : QStringLiteral("write"), detail);
    });
    jobThread_->start(QThread::LowPriority);
}

void AppImageUpdater::restart() {
    if (!staged_ || relaunch_) return;
    // only the file this melo verified: same inode, size and modification time
    Ident now, at;
    const bool same = identOf(stagedFd_, &now.dev, &now.ino, &now.size, &now.mtimeNs)
                      && identOfPath(stagedPath_, &at.dev, &at.ino)
                      && now.dev == ident_.dev && now.ino == ident_.ino && at.dev == ident_.dev
                      && at.ino == ident_.ino && now.size == ident_.size && now.size == control_->length
                      && now.mtimeNs == ident_.mtimeNs;
    if (!same) {
        dropStaged();
        return failWith(QStringLiteral("damaged"), QStringLiteral("the update file changed after it was verified"));
    }
    const QByteArray from = QFile::encodeName(stagedPath_), to = QFile::encodeName(appImage_);
    // rename(2) replaces in one step: the old file stays whole until the new one is in place
    if (::rename(from.constData(), to.constData()) != 0) {
        const QString why = QString::fromLocal8Bit(std::strerror(errno));
        return failWith(QStringLiteral("replace"), why);
    }
    const int dirFd = ::open(QFile::encodeName(QFileInfo(appImage_).absolutePath()).constData(),
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirFd >= 0) { ::fsync(dirFd); ::close(dirFd); }
    ::close(stagedFd_);
    stagedFd_ = -1;
    staged_ = false;
    relaunch_ = true;
    logLine(QStringLiteral("replaced %1 with %2, restarting").arg(appImage_, version_));
    if (quit_) quit_(); else QCoreApplication::quit();
}

void AppImageUpdater::retry() {
    if (state_ != QLatin1String("failed")) return;
    if (errorKind_ == QLatin1String("replace")) { restart(); return; }
    update();
}

bool AppImageUpdater::relaunch() const {
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // the old mount's paths: the new AppImage's runtime and AppRun set their own
    // A list such as PATH keeps its other entries: the anylinux AppRun puts the mount first.
    const QString mount = env.value(QStringLiteral("APPDIR"));
    for (const QString& k : env.keys()) {
        if (mount.isEmpty() || !env.value(k).contains(mount)) continue;
        QStringList keep = env.value(k).split(u':');
        keep.removeIf([&mount](const QString& e) { return e.contains(mount); });
        if (keep.isEmpty()) env.remove(k); else env.insert(k, keep.join(u':'));
    }
    const QString owd = env.value(QStringLiteral("OWD"));
    for (const char* k : { "APPDIR", "APPIMAGE", "ARGV0", "OWD" }) env.remove(QString::fromLatin1(k));
    env.insert(QStringLiteral("MELO_UPDATE_RELAUNCH"), QStringLiteral("1"));
    QProcess p;
    p.setProgram(appImage_);
    p.setArguments(relaunchArgs(QCoreApplication::arguments().mid(1)));
    p.setProcessEnvironment(env);
    p.setWorkingDirectory(!owd.isEmpty() ? owd : QDir::currentPath());
    qint64 pid = 0;
    const bool ok = p.startDetached(&pid);
    logLine(ok ? QStringLiteral("started %1 (pid %2)").arg(appImage_).arg(pid)
               : QStringLiteral("could not start ") + appImage_);
    return ok;
}
