#include "LogFile.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QtLogging>
#include <atomic>
#include <algorithm>
#include <deque>
#include <thread>

#ifdef Q_OS_UNIX
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

LogFile::LogFile(const QString& dir, qint64 cap, int keep)
    : dir_(dir), path_(dir + QStringLiteral("/melo.log")), cap_(cap), keep_(keep) {
    QDir().mkpath(dir_);
    open();
}

LogFile::~LogFile() { if (f_) std::fclose(f_); }

void LogFile::open() {
    f_ = std::fopen(QFile::encodeName(path_).constData(), "ab");
    size_ = f_ ? QFileInfo(path_).size() : 0;
    // owner only, as settings.v2.json: it names what was played
    if (f_) QFile::setPermissions(path_, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

void LogFile::rotate() {
    if (f_) { std::fclose(f_); f_ = nullptr; }
    QFile::remove(path_ + QStringLiteral(".%1").arg(keep_));
    for (int i = keep_ - 1; i >= 1; --i)
        QFile::rename(path_ + QStringLiteral(".%1").arg(i), path_ + QStringLiteral(".%1").arg(i + 1));
    QFile::rename(path_, path_ + QStringLiteral(".1"));
    open();
}

void LogFile::writeLine(const QByteArray& line) {
    if (!f_) return;
    const QByteArray out = redact(line) + '\n';
    std::fwrite(out.constData(), 1, size_t(out.size()), f_);
    size_ += out.size();
    if (size_ >= cap_) rotate();
}

void LogFile::flush() { if (f_) std::fflush(f_); }

QByteArray LogFile::redact(const QByteArray& line) {
    // cheap gate: most lines carry none of these
    static const QByteArray hints[] = {"googlevideo", "ookie", "uthorization", "SAPISID", "SID=", "LOGIN_INFO",
                                       "__Secure-", "__Host-", "VISITOR_", "CONSENT", "ST-", "=", "\":",
                                       "\tTRUE\t", "\tFALSE\t", "domain"};
    bool maybe = false;
    for (const QByteArray& h : hints) if (line.contains(h)) { maybe = true; break; }
    if (!maybe) return line;
    struct Rule { QRegularExpression re; QString with; };
    static const Rule rules[] = {
        { QRegularExpression(QStringLiteral(R"re(https?://[^\s"'<>]*googlevideo\.com[^\s"'<>]*)re")),
          QStringLiteral("<googlevideo url>") },
        { QRegularExpression(QStringLiteral(R"re(\b((?:set-)?cookie|authorization|x-goog-visitor-id)(\s*[:=]\s*)[^\r\n]+)re"),
                             QRegularExpression::CaseInsensitiveOption),
          QStringLiteral("\\1\\2<redacted>") },
        { QRegularExpression(QStringLiteral(R"re(\bSAPISID(?:1P|3P)?HASH\s+\S+)re")), QStringLiteral("SAPISIDHASH <redacted>") },
        { QRegularExpression(QStringLiteral(R"re(\b(SAPISID|APISID|HSID|SSID|SID|SIDCC|LSID|OSID|NID|YSC|PREF|SOCS|AEC|CONSENT|LOGIN_INFO|VISITOR_INFO1_LIVE|VISITOR_PRIVACY_METADATA|__Secure-[0-9A-Za-z_-]+|__Host-[0-9A-Za-z_-]+|ST-[0-9A-Za-z_-]+)=[^;\s"',]+)re")),
          QStringLiteral("\\1=<redacted>") },
        // a cookies.txt line: domain, flag, path, secure, expiry, name, value;
        // anywhere on the line, as the sidecar's lines carry a prefix
        { QRegularExpression(QStringLiteral(R"re((^|\s)(\S+\t(?:TRUE|FALSE)\t\S*\t(?:TRUE|FALSE)\t-?\d*\t[^\t]*\t)[^\t\r\n]*)re")),
          QStringLiteral("\\1\\2<redacted>") },
        // a raw header pair, as Node prints one: ['cookie', '…'] or ["set-cookie","…"]
        { QRegularExpression(QStringLiteral(R"re((['"])((?:set-)?cookie|authorization)\1(\s*,\s*)(['"])(?:(?!\4).)*\4)re"),
                             QRegularExpression::CaseInsensitiveOption),
          QStringLiteral("\\1\\2\\1\\3\\4<redacted>\\4") },
        { QRegularExpression(QStringLiteral(R"re(([?&;](?:sig|signature|lsig|key|api_key|apikey|token|pot|access_token|refresh_token|visitorData|visitor_data)=)[^&\s"'#]+)re"),
                             QRegularExpression::CaseInsensitiveOption),
          QStringLiteral("\\1<redacted>") },
        { QRegularExpression(QStringLiteral(R"re("(visitorData|poToken|po_token|lastfmApiKey|apiKey|api_key|token|accessToken|refreshToken|cookie|cookies)"\s*:\s*"[^"]*")re"),
                             QRegularExpression::CaseInsensitiveOption),
          QStringLiteral("\"\\1\":\"<redacted>\"") },
        { QRegularExpression(QStringLiteral(R"re(\b(visitorData|poToken|po_token|lastfmApiKey|apiKey|api_key)(\s*[:=]\s*)(?!<redacted>)[A-Za-z0-9_\-%.=]{8,})re")),
          QStringLiteral("\\1\\2<redacted>") },
    };
    QString s = QString::fromUtf8(line);
    for (const Rule& r : rules) s.replace(r.re, r.with);
    // a cookie object, as JSON ({"domain":..,"value":"…"}) or as Node's inspect
    // prints one ({ domain: .., value: '…' }): every value on the line
    if (s.contains(QLatin1String("domain"))) {
        static const QRegularExpression json(QStringLiteral(R"re("value"\s*:\s*"(?:[^"\\]|\\.)*")re"));
        static const QRegularExpression inspect(QStringLiteral(R"re(\bvalue\s*:\s*'(?:[^'\\]|\\.)*')re"));
        s.replace(json, QStringLiteral("\"value\":\"<redacted>\""));
        s.replace(inspect, QStringLiteral("value: '<redacted>'"));
    }
    return s.toUtf8();
}

// ---- the tee ----

namespace {
std::atomic<bool> g_running{false};
LogFile* g_log = nullptr;
std::thread g_worker;
int g_origErr = -1, g_errRead = -1, g_qtWrite = -1, g_qtRead = -1;
std::FILE* g_teeFile = nullptr;
std::FILE* g_stdErr = nullptr;
bool g_appendQt = false;
QtMessageHandler g_prev = nullptr;

void writeAll(int fd, const char* p, ssize_t n) {
#ifdef Q_OS_UNIX
    while (n > 0) {
        const ssize_t w = ::write(fd, p, size_t(n));
        if (w < 0) { if (errno == EINTR) continue; return; }
        p += w; n -= w;
    }
#endif
}

// Qt's messages when Qt does not print them to stderr itself
void teeHandler(QtMsgType type, const QMessageLogContext& ctx, const QString& msg) {
#ifdef Q_OS_UNIX
    if (g_appendQt && g_running.load()) {
        const QByteArray line = qFormatLogMessage(type, ctx, msg).toUtf8() + '\n';
        writeAll(g_qtWrite, line.constData(), line.size());
    }
#endif
    if (g_prev) g_prev(type, ctx, msg);
}

#ifdef Q_OS_UNIX
// Qt's messages arrive twice when Qt also prints them to stderr: the handler's
// copy is read first (its pipe is drained before fd 2) and the stderr copy that
// matches it is not logged again. The real stderr (the journal, when started
// from a .desktop file) gets the redacted line too; a line without its newline
// goes out after 250 ms of quiet.
void work() {
    QByteArray pending[2];   // [0] the Qt pipe, [1] fd 2
    qsizetype echoed = 0;    // bytes of pending[1] already on the real stderr
    const auto echo = [](const QByteArray& part, bool newline) {
        const QByteArray out = LogFile::redact(part) + (newline ? "\n" : "");
        writeAll(g_origErr, out.constData(), out.size());
    };
    std::deque<QByteArray> recentQt;
    char buf[16384];
    bool qtOpen = true;
    for (;;) {
        pollfd fds[2] = {{g_qtRead, POLLIN, 0}, {g_errRead, POLLIN, 0}};
        const int r = ::poll(fds, 2, qtOpen ? 250 : 0);
        if (r < 0 && errno == EINTR) continue;
        bool any = false;
        for (int i = 0; i < 2; ++i) {
            if (i == 0 && !qtOpen) continue;
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            const ssize_t n = ::read(fds[i].fd, buf, sizeof buf);
            if (n > 0) {
                any = true;
                pending[i].append(buf, int(n));
                qsizetype nl;
                while ((nl = pending[i].indexOf('\n')) >= 0) {
                    const QByteArray line = pending[i].left(nl);
                    pending[i].remove(0, nl + 1);
                    if (i == 1) { echo(line.mid(echoed), true); echoed = 0; }
                    if (i == 0) {
                        recentQt.push_back(line);
                        if (recentQt.size() > 64) recentQt.pop_front();
                    } else {
                        auto hit = std::find(recentQt.begin(), recentQt.end(), line);
                        if (hit != recentQt.end()) { recentQt.erase(hit); continue; }
                    }
                    g_log->writeLine(line);
                }
            } else if (i == 0 && (n == 0 || (errno != EAGAIN && errno != EINTR))) {
                qtOpen = false;   // stopTee closed it: drain fd 2 and end
            }
        }
        if (any) g_log->flush();
        else if (pending[1].size() > echoed) { echo(pending[1].mid(echoed), false); echoed = pending[1].size(); }
        if (!qtOpen && !any) break;
    }
    if (pending[1].size() > echoed) echo(pending[1].mid(echoed), false);
    for (QByteArray& p : pending) if (!p.isEmpty()) g_log->writeLine(p);
    g_log->flush();
}
#endif
}  // namespace

// fd 2 itself is never touched: every process melo starts inherits the real
// stderr, so none holds the pipe and none can die of SIGPIPE once melo has
// quit. Only melo's stdio `stderr` stream is pointed at the pipe; the pipe's
// write end is close-on-exec.
bool LogFile::startTee(const QString& dir, bool smoke) {
#if defined(Q_OS_UNIX) && defined(__GLIBC__)
    if (g_running.load()) return true;
    int ep[2], qp[2];
    if (::pipe2(ep, O_CLOEXEC) != 0) return false;
    if (::pipe2(qp, O_CLOEXEC) != 0) { ::close(ep[0]); ::close(ep[1]); return false; }
    std::FILE* tee = ::fdopen(ep[1], "w");
    if (!tee) { for (int fd : {ep[0], ep[1], qp[0], qp[1]}) ::close(fd); return false; }
    std::setvbuf(tee, nullptr, _IONBF, 0);   // as main() sets stderr: a crash loses nothing buffered
    std::fflush(stderr);
    g_origErr = ::fcntl(2, F_DUPFD_CLOEXEC, 3);
    g_log = new LogFile(dir);
    g_errRead = ep[0]; g_qtRead = qp[0]; g_qtWrite = qp[1];
    ::fcntl(g_errRead, F_SETFL, ::fcntl(g_errRead, F_GETFL) | O_NONBLOCK);
    ::fcntl(g_qtRead, F_SETFL, ::fcntl(g_qtRead, F_GETFL) | O_NONBLOCK);
    // the smoke handler prints every message itself, unformatted
    g_appendQt = !smoke;
    g_running = true;
    g_teeFile = tee;
    g_stdErr = stderr;
    stderr = tee;
    g_prev = qInstallMessageHandler(&teeHandler);
    g_worker = std::thread(work);
    return true;
#else
    Q_UNUSED(dir); Q_UNUSED(smoke);
    return false;
#endif
}

void LogFile::stopTee() {
#if defined(Q_OS_UNIX) && defined(__GLIBC__)
    if (!g_running.load()) return;
    qInstallMessageHandler(g_prev);
    g_running = false;
    stderr = g_stdErr;
    // The stream stays open: GStreamer and GLib keep the stderr they saw at
    // init. Its fd now points at the real stderr, which also closes the pipe.
    std::fflush(g_teeFile);
    ::dup2(g_origErr, ::fileno(g_teeFile));
    ::close(g_qtWrite);         // tells the worker to drain and end
    g_worker.join();
    ::close(g_errRead); ::close(g_qtRead); ::close(g_origErr);
    delete g_log; g_log = nullptr;
#endif
}

bool LogFile::teeRunning() { return g_running.load(); }
