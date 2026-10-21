#include <QtTest>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QThread>
#include <QDir>
#include <QElapsedTimer>
#include <memory>
#include <QtEndian>
#include <unistd.h>

#include "AppImageInfo.h"
#include "AppImageUpdater.h"
#include "Zsync.h"
#include "ZsyncJob.h"
#include "paths.h"
#include "FollowTracer.h"
#include <poll.h>
#include <sys/ptrace.h>
#include <sys/wait.h>

// The AppImage updater: zsync 0.6.2's control file and block matching, the
// HTTP Range fetch of the rest, the ELF update information, and the decision
// that an update exists. A local server stands in for GitHub.

namespace {

// zsyncmake's output for `data` (make.c): the header, then per block the
// trailing rsumBytes of big-endian (a, b) and the leading checksumBytes of MD4.
QByteArray makeZsync(const QByteArray& data, int bs, int seq, int rsumBytes, int checksumBytes,
                     const QByteArray& url, const QByteArray& filename, const QByteArray& mtime = "Thu, 01 Jan 2026 00:00:00 +0000") {
    QByteArray out;
    out += "zsync: 0.6.2\n";
    out += "Filename: " + filename + "\n";
    out += "MTime: " + mtime + "\n";
    out += "Blocksize: " + QByteArray::number(bs) + "\n";
    out += "Length: " + QByteArray::number(data.size()) + "\n";
    out += "Hash-Lengths: " + QByteArray::number(seq) + "," + QByteArray::number(rsumBytes) + "," + QByteArray::number(checksumBytes) + "\n";
    out += "URL: " + url + "\n";
    out += "SHA-1: " + QCryptographicHash::hash(data, QCryptographicHash::Sha1).toHex() + "\n\n";
    for (qsizetype off = 0; off < data.size(); off += bs) {
        QByteArray block = data.mid(off, bs);
        block.append(QByteArray(bs - block.size(), '\0'));
        const zsync::Rsum r = zsync::rsumBlock(reinterpret_cast<const uchar*>(block.constData()), bs);
        uchar be[4];
        qToBigEndian<quint16>(r.a, be);
        qToBigEndian<quint16>(r.b, be + 2);
        out.append(reinterpret_cast<const char*>(be) + 4 - rsumBytes, rsumBytes);
        out += QCryptographicHash::hash(block, QCryptographicHash::Md4).left(checksumBytes);
    }
    return out;
}

QByteArray xorshift(qsizetype n, quint32 x = 0x12345678) {
    QByteArray out(n, '\0');
    for (qsizetype i = 0; i < n; ++i) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        out[i] = char(x & 0xff);
    }
    return out;
}

QByteArray randomBytes(qsizetype n, quint32 seed) {
    QRandomGenerator g(seed);
    QByteArray out(n, '\0');
    for (qsizetype i = 0; i < n; ++i) out[i] = char(g.bounded(256));
    return out;
}

// old: A B C D E; new: A B' (changed) C, 777 inserted bytes, D, E (shortened)
struct Pair { QByteArray oldData, newData; };
Pair makePair(int bs) {
    const QByteArray a = randomBytes(bs * 200 + 13, 1), b = randomBytes(bs * 10, 2), c = randomBytes(bs * 150 + 501, 3),
                     d = randomBytes(bs * 125, 4), e = randomBytes(bs * 100 + 99, 5);
    Pair p;
    p.oldData = a + b + c + d + e;
    p.newData = a + randomBytes(bs * 10, 6) + c + randomBytes(777, 7) + d + e.left(e.size() - 1234);
    return p;
}

// HTTP/1.1, one request per connection. Honours a single Range unless told
// not to; /r/<name> redirects to the second server's /f/<name>.
class Server : public QObject {
public:
    QTcpServer tcp;
    QHash<QByteArray, QByteArray> files;
    QByteArray redirectTo;    // base URL for /r/ paths
    bool honourRange = true;
    qint64 stallAfter = -1;   // a Range answer sends this many bytes, then nothing
    bool emptyOk = false;     // a Range answer is 200 with no body
    qint64 bodyBytes = 0;
    int requests = 0, rangeRequests = 0, redirects = 0;
    QHash<QByteArray, QByteArray> corrupt;   // path -> served instead

    Server() {
        tcp.listen(QHostAddress::LocalHost);
        connect(&tcp, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket* s = tcp.nextPendingConnection()) {
                auto* buf = new QByteArray;
                connect(s, &QTcpSocket::disconnected, s, [s, buf] { delete buf; s->deleteLater(); });
                connect(s, &QTcpSocket::readyRead, s, [this, s, buf] {
                    *buf += s->readAll();
                    if (!buf->contains("\r\n\r\n")) return;
                    answer(s, *buf);
                    buf->clear();
                });
            }
        });
    }
    QByteArray base() const { return "http://127.0.0.1:" + QByteArray::number(tcp.serverPort()); }

    void answer(QTcpSocket* s, const QByteArray& req) {
        ++requests;
        const QList<QByteArray> lines = req.left(req.indexOf("\r\n\r\n")).split('\n');
        const QByteArray path = lines.value(0).split(' ').value(1);
        QByteArray range;
        for (const QByteArray& l : lines)
            if (l.toLower().startsWith("range:")) range = l.mid(6).trimmed();
        auto send = [s](const QByteArray& head, const QByteArray& body) {
            s->write(head + "Content-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
            s->disconnectFromHost();
        };
        if (path.startsWith("/r/")) {
            ++redirects;
            return send("HTTP/1.1 302 Found\r\nLocation: " + redirectTo + "/f/" + path.mid(3) + "\r\n", {});
        }
        const QByteArray name = path.startsWith("/f/") ? path.mid(3) : path.mid(1);
        if (!files.contains(name)) return send("HTTP/1.1 404 Not Found\r\n", {});
        const QByteArray data = corrupt.value(name, files.value(name));
        if (!range.isEmpty() && emptyOk) return send("HTTP/1.1 200 OK\r\n", {});
        if (!range.isEmpty() && honourRange) {
            ++rangeRequests;
            const QList<QByteArray> ab = range.mid(6).split('-');
            const qint64 from = ab.value(0).toLongLong(), to = qMin<qint64>(ab.value(1).toLongLong(), data.size() - 1);
            const QByteArray body = data.mid(from, to - from + 1);
            if (stallAfter >= 0) {
                s->write("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " + QByteArray::number(from) + "-"
                         + QByteArray::number(to) + "/" + QByteArray::number(data.size()) + "\r\nContent-Length: "
                         + QByteArray::number(body.size()) + "\r\n\r\n" + body.left(stallAfter));
                return;
            }
            bodyBytes += body.size();
            return send("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " + QByteArray::number(from) + "-"
                        + QByteArray::number(to) + "/" + QByteArray::number(data.size()) + "\r\n", body);
        }
        bodyBytes += data.size();
        send("HTTP/1.1 200 OK\r\n", data);
    }
};

QByteArray sha1Of(const QString& path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QCryptographicHash::hash(f.readAll(), QCryptographicHash::Sha1).toHex();
}
bool writeFile(const QString& path, const QByteArray& data) {
    QFile f(path);
    return f.open(QIODevice::WriteOnly | QIODevice::Truncate) && f.write(data) == data.size();
}
QByteArray readFile(const QString& path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

// A minimal ELF64 with .shstrtab and the given sections, then `payload` (an
// AppImage's squashfs sits after its runtime the same way).
QByteArray makeElf(const QList<QPair<QByteArray, QByteArray>>& sections, const QByteArray& payload = {}) {
    QByteArray strtab("\0", 1);
    QList<quint32> nameAt;
    for (const auto& s : sections) { nameAt << quint32(strtab.size()); strtab += s.first + '\0'; }
    const quint32 shstrName = quint32(strtab.size());
    strtab += QByteArray(".shstrtab") + '\0';

    QByteArray body;   // section contents start at 64
    QList<quint64> offs;
    for (const auto& s : sections) { offs << quint64(64 + body.size()); body += s.second; }
    const quint64 strOff = 64 + body.size();
    body += strtab;
    while (body.size() % 8) body += '\0';
    const quint64 shoff = 64 + body.size();
    const int shnum = int(sections.size()) + 2;   // null, sections, shstrtab

    QByteArray h(64, '\0');
    h[0] = 0x7f; h[1] = 'E'; h[2] = 'L'; h[3] = 'F'; h[4] = 2; h[5] = 1; h[6] = 1;
    uchar* p = reinterpret_cast<uchar*>(h.data());
    qToLittleEndian<quint16>(2, p + 0x10);          // ET_EXEC
    qToLittleEndian<quint16>(62, p + 0x12);         // x86-64
    qToLittleEndian<quint32>(1, p + 0x14);
    qToLittleEndian<quint64>(shoff, p + 0x28);
    qToLittleEndian<quint16>(64, p + 0x34);
    qToLittleEndian<quint16>(64, p + 0x3A);
    qToLittleEndian<quint16>(quint16(shnum), p + 0x3C);
    qToLittleEndian<quint16>(quint16(shnum - 1), p + 0x3E);

    QByteArray sh(64 * shnum, '\0');
    auto entry = [&](int i, quint32 name, quint64 off, quint64 size) {
        uchar* e = reinterpret_cast<uchar*>(sh.data()) + 64 * i;
        qToLittleEndian<quint32>(name, e);
        qToLittleEndian<quint32>(i == shnum - 1 ? 3 : 1, e + 4);   // STRTAB / PROGBITS
        qToLittleEndian<quint64>(off, e + 0x18);
        qToLittleEndian<quint64>(size, e + 0x20);
    };
    for (int i = 0; i < sections.size(); ++i) entry(i + 1, nameAt[i], offs[i], quint64(sections[i].second.size()));
    entry(shnum - 1, shstrName, strOff, quint64(strtab.size()));
    return h + body + sh + payload;
}

QByteArray updInfo(const QByteArray& s) {
    QByteArray b = s;
    b.append(QByteArray(1024 - b.size(), '\0'));
    return b;
}

// An AppImage in `dir` and a server with a newer release of it.
struct Release {
    QByteArray oldFile, newFile;
    QString app;
    Server gh;
    Release(const QString& dir, const QString& tag = "alpha-5", const QString& name = "m.AppImage") {
        const QByteArray info = updInfo("gh-releases-zsync|o|r|latest|m.zsync");
        oldFile = makeElf({ { ".upd_info", info } }, makePair(2048).oldData);
        newFile = makeElf({ { ".upd_info", info } }, makePair(2048).newData);
        app = dir + "/" + name;
        writeFile(app, oldFile);
        gh.files["m.AppImage"] = newFile;
        gh.files["m.zsync"] = makeZsync(newFile, 2048, 2, 2, 5, "m.AppImage", "m.AppImage");
        gh.files["latest"] = QJsonDocument(QJsonObject { { "tag_name", tag }, { "assets", QJsonArray {
            QJsonObject { { "name", "m.zsync" }, { "browser_download_url", QString(gh.base() + "/m.zsync") } } } } }).toJson();
    }
    QUrl api() const { return QUrl(gh.base() + "/latest"); }
};

// checks, and Updates when there is one; the state it ends in
QString checkAndUpdate(AppImageUpdater& u, const QUrl& api) {
    u.setApiUrl(api);
    u.setQuit([] {});
    QSignalSpy checked(&u, &AppImageUpdater::checkDone);
    u.check();
    if (!checked.wait(10000)) return "no check";
    if (u.state() != "available") return u.state();
    u.update();
    QElapsedTimer t; t.start();
    while (u.state() == "downloading" && t.elapsed() < 30000) QTest::qWait(20);
    return u.state();
}

QStringList updateFiles(const QString& dir) {
    return QDir(dir).entryList({ "*.update-*" }, QDir::Files | QDir::Hidden);
}

}   // namespace

class TstAppImageUpdate : public QObject {
    Q_OBJECT

    struct Run {
        bool ok = false;
        ZsyncJob::Failure why = ZsyncJob::Network;
        QString detail;
        qint64 fetched = 0, have = 0, blocks = 0;
    };
    // runs a job on its own thread, as the updater does
    Run runJob(const zsync::Control& c, const QUrl& controlUrl, const QString& source, const QString& out) {
        Run r;
        QThread t;
        auto* job = new ZsyncJob(c, controlUrl, source, out);
        job->moveToThread(&t);
        bool done = false;
        connect(&t, &QThread::started, job, &ZsyncJob::start);
        connect(job, &ZsyncJob::scanned, this, [&](qint64 h, qint64 n) { r.have = h; r.blocks = n; });
        connect(job, &ZsyncJob::finished, this, [&](const QString&, qint64 f) { r.ok = true; r.fetched = f; done = true; });
        connect(job, &ZsyncJob::failed, this, [&](ZsyncJob::Failure w, const QString& d) { r.why = w; r.detail = d; done = true; });
        t.start();
        [&] { QTRY_VERIFY_WITH_TIMEOUT(done, 30000); }();
        QMetaObject::invokeMethod(job, "deleteLater");
        t.quit();
        t.wait();
        return r;
    }

private slots:
    void rsumRollsLikeTheBlockSum() {
        const QByteArray d = randomBytes(9000, 11);
        const uchar* p = reinterpret_cast<const uchar*>(d.constData());
        const int bs = 1024, shift = 10;
        zsync::Rsum r = zsync::rsumBlock(p, bs);
        for (int x = 0; x + bs < d.size(); ++x) {
            zsync::rsumRoll(r, p[x], p[x + bs], shift);
            const zsync::Rsum want = zsync::rsumBlock(p + x + 1, bs);
            QCOMPARE(r.a, want.a);
            QCOMPARE(r.b, want.b);
        }
        // librcksum's weighting: b is sum of (len - i) * c[i]
        const uchar three[3] = { 1, 2, 3 };
        const zsync::Rsum s = zsync::rsumBlock(three, 3);
        QCOMPARE(int(s.a), 6);
        QCOMPARE(int(s.b), 3 * 1 + 2 * 2 + 1 * 3);
    }

    // tests/cpp/data/zsync/xorshift-70001.zsync is zsyncmake 0.6.2's own output
    // (-b 2048) for xorshift(70001); the generator here must agree with it byte
    // for byte, and the parser must read it.
    void matchesRealZsyncmake() {
        const QByteArray real = readFile(QStringLiteral(MELO_SOURCE_DIR "/tests/cpp/data/zsync/xorshift-70001.zsync"));
        QVERIFY(!real.isEmpty());
        const QByteArray data = xorshift(70001);
        QString err;
        const auto c = zsync::parse(real, &err);
        QVERIFY2(c, qPrintable(err));
        QCOMPARE(c->filename, QString("fixture.bin"));
        QCOMPARE(c->url, QString("fixture.bin"));
        QCOMPARE(c->length, qint64(70001));
        QCOMPARE(c->blocksize, 2048);
        QCOMPARE(c->seqMatches, 2);
        QCOMPARE(c->rsumBytes, 2);
        QCOMPARE(c->checksumBytes, 4);
        QCOMPARE(c->sha1, QCryptographicHash::hash(data, QCryptographicHash::Sha1).toHex());
        QCOMPARE(c->blockCount(), qint64(35));
        const QByteArray mine = makeZsync(data, 2048, 2, 2, 4, "fixture.bin", "fixture.bin",
                                          c->mtime.toUtf8());
        QCOMPARE(mine, real);
        // the table's rsum b and MD4 prefix are those of each (padded) block
        for (qint64 id = 0; id < c->blockCount(); ++id) {
            QByteArray block = data.mid(id * 2048, 2048);
            block.append(QByteArray(2048 - block.size(), '\0'));
            const zsync::Rsum r = zsync::rsumBlock(reinterpret_cast<const uchar*>(block.constData()), 2048);
            QVERIFY(c->weakMatches(id, r));
            QVERIFY(c->strongMatches(id, reinterpret_cast<const uchar*>(block.constData())));
        }
    }

    void rejectsWhatZsyncRejects() {
        QVERIFY(!zsync::parse("not a zsync file\n\n"));
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 1000\nLength: 10\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\n"));
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 1024\nLength: 4000\nHash-Lengths: 3,2,4\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\n"));
        // four blocks need 4 * 6 table bytes
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 1024\nLength: 4000\nHash-Lengths: 2,2,4\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\nshort"));
    }

    void scanFindsSharedBlocksAcrossAShift() {
        const Pair p = makePair(1024);
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old.bin");
        QVERIFY(writeFile(oldPath, p.oldData));
        const auto c = zsync::parse(makeZsync(p.newData, 1024, 2, 3, 5, "new.bin", "new.bin"));
        QVERIFY(c);
        QFile out(dir.filePath("out.bin"));
        QVERIFY(out.open(QIODevice::ReadWrite));
        std::vector<char> have;
        QVERIFY(zsync::scan(*c, oldPath, out, have));
        qint64 got = 0;
        for (char h : have) got += h;
        // a, c, d and most of e survive; b' and the blocks the insert and the
        // shortening touch do not
        QVERIFY2(got > c->blockCount() * 8 / 10, qPrintable(QString("%1 of %2").arg(got).arg(c->blockCount())));
        QVERIFY(got < c->blockCount());
        // every block marked had is the new file's
        out.flush();
        const QByteArray built = readFile(out.fileName());
        for (qint64 id = 0; id < c->blockCount(); ++id)
            if (have[size_t(id)])
                QCOMPARE(built.mid(c->blockStart(id), c->blockLen(id)), p.newData.mid(c->blockStart(id), c->blockLen(id)));
    }

    void missingRangesMergeSmallGaps() {
        const std::vector<char> have { 1, 0, 0, 1, 0, 1, 1, 1, 0 };
        auto r = zsync::missingRanges(have, 0);
        QCOMPARE(int(r.size()), 3);
        QCOMPARE(r[0], (std::pair<qint64, qint64>(1, 2)));
        QCOMPARE(r[1], (std::pair<qint64, qint64>(4, 4)));
        QCOMPARE(r[2], (std::pair<qint64, qint64>(8, 8)));
        r = zsync::missingRanges(have, 1);
        QCOMPARE(int(r.size()), 2);
        QCOMPARE(r[0], (std::pair<qint64, qint64>(1, 4)));
    }

    void deltaDownloadRebuildsTheNewFile_data() {
        QTest::addColumn<int>("bs");
        QTest::addColumn<int>("seq");
        QTest::addColumn<int>("rsumBytes");
        QTest::addColumn<int>("checksumBytes");
        QTest::newRow("appimagetool's 2048, 2,2,5") << 2048 << 2 << 2 << 5;
        QTest::newRow("1024, 2,3,4") << 1024 << 2 << 3 << 4;
        QTest::newRow("4096, one match, full sums") << 4096 << 1 << 4 << 16;
    }
    void deltaDownloadRebuildsTheNewFile() {
        QFETCH(int, bs); QFETCH(int, seq); QFETCH(int, rsumBytes); QFETCH(int, checksumBytes);
        const Pair p = makePair(bs);
        Server front, cdn;
        front.redirectTo = cdn.base();
        cdn.files["new.bin"] = p.newData;
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("melo.AppImage"), out = dir.filePath(".melo.AppImage.update");
        QVERIFY(writeFile(oldPath, p.oldData));
        const auto c = zsync::parse(makeZsync(p.newData, bs, seq, rsumBytes, checksumBytes, "new.bin", "new.bin"));
        QVERIFY(c);
        // the .zsync's URL is relative to the .zsync, which redirects like GitHub's
        const Run r = runJob(*c, QUrl(front.base() + "/r/new.bin.zsync"), oldPath, out);
        QVERIFY2(r.ok, qPrintable(r.detail));
        QCOMPARE(readFile(out), p.newData);
        QCOMPARE(readFile(oldPath), p.oldData);
        QVERIFY(front.redirects > 0);
        QCOMPARE(cdn.rangeRequests, cdn.requests);
        QVERIFY2(cdn.bodyBytes < p.newData.size() / 4,
                 qPrintable(QString("fetched %1 of %2").arg(cdn.bodyBytes).arg(p.newData.size())));
        QCOMPARE(r.fetched, cdn.bodyBytes);
    }

    void serverIgnoringRangeStillBuildsIt() {
        const Pair p = makePair(2048);
        Server s;
        s.honourRange = false;
        s.files["new.bin"] = p.newData;
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old"), out = dir.filePath("out");
        QVERIFY(writeFile(oldPath, p.oldData));
        const auto c = zsync::parse(makeZsync(p.newData, 2048, 2, 2, 5, "new.bin", "new.bin"));
        const Run r = runJob(*c, QUrl(s.base() + "/new.bin.zsync"), oldPath, out);
        QVERIFY2(r.ok, qPrintable(r.detail));
        QCOMPARE(readFile(out), p.newData);
    }

    void damagedDownloadLeavesNothingBehind() {
        const Pair p = makePair(2048);
        Server s;
        s.files["new.bin"] = p.newData;
        QByteArray bad = p.newData;
        for (int i = 0; i < 4096; ++i) bad[2048 * 205 + i] = char(~bad[2048 * 205 + i]);   // inside b'
        s.corrupt["new.bin"] = bad;
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old"), out = dir.filePath("out");
        QVERIFY(writeFile(oldPath, p.oldData));
        const QByteArray before = sha1Of(oldPath);
        const auto c = zsync::parse(makeZsync(p.newData, 2048, 2, 2, 5, "new.bin", "new.bin"));
        const Run r = runJob(*c, QUrl(s.base() + "/new.bin.zsync"), oldPath, out);
        QVERIFY(!r.ok);
        QCOMPARE(r.why, ZsyncJob::Damaged);
        QVERIFY(!QFile::exists(out));
        QCOMPARE(sha1Of(oldPath), before);
    }

    // blocks that all check out but a whole that does not: the SHA-1 catches it
    void checksumMismatchLeavesTheOriginal() {
        const Pair p = makePair(2048);
        Server s;
        s.files["new.bin"] = p.newData;
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old"), out = dir.filePath("out");
        QVERIFY(writeFile(oldPath, p.oldData));
        QByteArray z = makeZsync(p.newData, 2048, 2, 2, 5, "new.bin", "new.bin");
        const qsizetype at = z.indexOf("SHA-1: ") + 7;
        z.replace(at, 40, QByteArray(40, '0'));
        const auto c = zsync::parse(z);
        QVERIFY(c);
        const Run r = runJob(*c, QUrl(s.base() + "/new.bin.zsync"), oldPath, out);
        QVERIFY(!r.ok);
        QCOMPARE(r.why, ZsyncJob::Damaged);
        QVERIFY(r.detail.contains("SHA-1"));
        QVERIFY(!QFile::exists(out));
        QCOMPARE(readFile(oldPath), p.oldData);
    }

    void networkFailureLeavesNothingBehind() {
        const Pair p = makePair(2048);
        Server s;   // has no new.bin: every range is a 404
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old"), out = dir.filePath("out");
        QVERIFY(writeFile(oldPath, p.oldData));
        const auto c = zsync::parse(makeZsync(p.newData, 2048, 2, 2, 5, "new.bin", "new.bin"));
        const Run r = runJob(*c, QUrl(s.base() + "/new.bin.zsync"), oldPath, out);
        QVERIFY(!r.ok);
        QCOMPARE(r.why, ZsyncJob::Network);
        QVERIFY(!QFile::exists(out));
    }

    // MELO_ZSYNC_REAL=<dir> with old/, new/ each holding an AppImage and new/
    // its .zsync (two published releases): the real file rebuilds from the old.
    void realReleasesWhenGiven() {
        const QString dirEnv = qEnvironmentVariable("MELO_ZSYNC_REAL");
        if (dirEnv.isEmpty()) QSKIP("MELO_ZSYNC_REAL not set");
        const QString name = qEnvironmentVariable("MELO_ZSYNC_NAME", "melo-lite-x86_64.AppImage");
        const QByteArray control = readFile(dirEnv + "/new/" + name + ".zsync");
        const auto c = zsync::parse(control);
        QVERIFY(c);
        Server s;
        s.files[name.toUtf8()] = readFile(dirEnv + "/new/" + name);
        // MELO_ZSYNC_URL: the published .zsync's own URL, so the ranges go to GitHub
        const QString remote = qEnvironmentVariable("MELO_ZSYNC_URL");
        QTemporaryDir dir;
        const QString out = dir.filePath("out");
        QElapsedTimer t; t.start();
        const Run r = runJob(*c, QUrl(remote.isEmpty() ? s.base() + "/" + name + ".zsync" : remote.toUtf8()),
                             dirEnv + "/old/" + name, out);
        QVERIFY2(r.ok, qPrintable(r.detail));
        qInfo("real: had %lld of %lld blocks, fetched %lld of %lld bytes in %lld requests, %lld ms",
              r.have, r.blocks, r.fetched, c->length, qint64(s.requests), t.elapsed());
        QCOMPARE(sha1Of(out), c->sha1);
    }

    // MELO_UPDATER_REAL=<a writable copy of an older published AppImage>: the
    // whole cycle against GitHub, ending with the file swapped for the release
    void realUpdaterWhenGiven() {
        const QString app = qEnvironmentVariable("MELO_UPDATER_REAL");
        if (app.isEmpty()) QSKIP("MELO_UPDATER_REAL not set");
        AppImageUpdater u(app);
        QVERIFY(u.supported());
        u.setQuit([] {});
        QSignalSpy checked(&u, &AppImageUpdater::checkDone);
        u.check();
        QVERIFY(checked.wait(30000));
        QCOMPARE(u.state(), QString("available"));
        qInfo("real: %s, notes %s", qPrintable(u.version()), qPrintable(u.notesUrl()));
        u.update();
        QTRY_VERIFY_WITH_TIMEOUT(u.state() != QString("downloading"), 120000);
        QCOMPARE(u.state(), QString("ready"));
        qInfo("real: fetched %lld of %lld bytes", u.fetched(), u.total());
        u.restart();
        QVERIFY(u.relaunchPending());
        AppImageUpdater after(app);
        QSignalSpy again(&after, &AppImageUpdater::checkDone);
        after.check();
        QVERIFY(again.wait(30000));
        QCOMPARE(after.state(), QString());
    }

    void readsTheElfUpdateInformation() {
        QTemporaryDir dir;
        const QString path = dir.filePath("melo-x86_64.AppImage");
        QVERIFY(writeFile(path, makeElf({ { ".note", "abc" },
            { ".upd_info", updInfo("gh-releases-zsync|melo-foundation|melo|latest|melo-x86_64.AppImage.zsync") },
            { ".sha256_sig", QByteArray(1024, '\0') } }, randomBytes(5000, 9))));
        const QByteArray raw = appimage::elfSection(path, ".upd_info");
        QCOMPARE(raw.size(), 1024);
        const appimage::UpdateInfo u = appimage::parseUpdateInfo(raw);
        QVERIFY(u.valid());
        QCOMPARE(u.owner, QString("melo-foundation"));
        QCOMPARE(u.repo, QString("melo"));
        QCOMPARE(u.channel, QString("latest"));
        QCOMPARE(u.zsyncName, QString("melo-x86_64.AppImage.zsync"));
        QCOMPARE(u.apiUrl(), QString("https://api.github.com/repos/melo-foundation/melo/releases/latest"));
        QVERIFY(appimage::elfSection(path, ".nope").isEmpty());
        QVERIFY(appimage::elfSection(dir.filePath("missing"), ".upd_info").isEmpty());
        // not an ELF
        QVERIFY(writeFile(dir.filePath("text"), QByteArray(200, 'x')));
        QVERIFY(appimage::elfSection(dir.filePath("text"), ".upd_info").isEmpty());
    }

    void parsesUpdateInformationStrings() {
        appimage::UpdateInfo n = appimage::parseUpdateInfo("gh-releases-zsync|o|r|nightly|melo-*-x86_64.AppImage.zsync");
        QVERIFY(n.valid());
        QCOMPARE(n.apiUrl(), QString("https://api.github.com/repos/o/r/releases/tags/nightly"));
        QVERIFY(n.matchesAsset("melo-lite-x86_64.AppImage.zsync"));
        QVERIFY(!n.matchesAsset("melo-lite-x86_64.AppImage"));
        QVERIFY(!n.matchesAsset("xmelo-lite-x86_64.AppImage.zsync"));
        QVERIFY(!appimage::parseUpdateInfo("zsync|https://example.org/x.zsync").valid());
        QVERIFY(!appimage::parseUpdateInfo("gh-releases-zsync|o|r|latest").valid());
        QVERIFY(!appimage::parseUpdateInfo(QByteArray(1024, '\0')).valid());
        QCOMPARE(appimage::versionLabel("alpha-5", "Alpha 5"), QString("melo 0.5.0"));
        QCOMPARE(appimage::versionLabel("alpha-3.1", "Alpha 3.1 (hotfix)"), QString("melo 0.3.1"));
        QCOMPARE(appimage::versionLabel("v1.2.3", ""), QString("melo 1.2.3"));
        QCOMPARE(appimage::versionLabel("nightly", "Nightly"), QString("melo Nightly"));
    }

    void notAnAppImageIsNotSupported() {
        AppImageUpdater none(QString{});
        QVERIFY(!none.supported());
        QTemporaryDir dir;
        const QString plain = dir.filePath("melo");
        QVERIFY(writeFile(plain, makeElf({ { ".text", "x" } })));
        AppImageUpdater noInfo(plain);
        QVERIFY(!noInfo.supported());
        qputenv("APPIMAGE", dir.filePath("gone.AppImage").toUtf8());
        QVERIFY(AppImageUpdater::runningAppImage().isEmpty());
        qputenv("APPIMAGE", plain.toUtf8());
        QCOMPARE(AppImageUpdater::runningAppImage(), plain);
        qunsetenv("APPIMAGE");
        QVERIFY(AppImageUpdater::runningAppImage().isEmpty());
    }

    void updateIsADifferentFile() {
        QVERIFY(AppImageUpdater::differs("aa", "bb"));
        QVERIFY(!AppImageUpdater::differs("AbC", "abc"));
        QVERIFY(!AppImageUpdater::differs("aa", ""));
    }

    // check -> available -> Update -> ready -> Restart swaps the files
    void updaterChecksDownloadsAndSwaps() {
        QTemporaryDir dir;
        const QByteArray info = updInfo("gh-releases-zsync|o|r|latest|melo-*.AppImage.zsync");
        const QByteArray oldFile = makeElf({ { ".upd_info", info } }, makePair(2048).oldData);
        const QByteArray newFile = makeElf({ { ".upd_info", info } }, makePair(2048).newData);
        const QString app = dir.filePath("melo-x86_64.AppImage");
        QVERIFY(writeFile(app, oldFile));
        QFile::setPermissions(app, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);

        Server gh;
        gh.files["melo-x86_64.AppImage"] = newFile;
        gh.files["melo-x86_64.AppImage.zsync"] = makeZsync(newFile, 2048, 2, 2, 5, "melo-x86_64.AppImage", "melo-x86_64.AppImage");
        auto release = [&](const QByteArray& zsyncName) {
            return QJsonDocument(QJsonObject {
                { "tag_name", "alpha-5" }, { "name", "Alpha 5" },
                { "html_url", "https://example.org/releases/alpha-5" },
                { "assets", QJsonArray {
                    QJsonObject { { "name", "melo-x86_64.AppImage" }, { "browser_download_url", QString(gh.base() + "/melo-x86_64.AppImage") } },
                    QJsonObject { { "name", QString(zsyncName) }, { "browser_download_url", QString(gh.base() + "/melo-x86_64.AppImage.zsync") } } } } })
                .toJson();
        };
        gh.files["latest"] = release("melo-x86_64.AppImage.zsync");

        AppImageUpdater u(app);
        QVERIFY(u.supported());
        QVERIFY(u.canUpdate());
        u.setApiUrl(QUrl(gh.base() + "/latest"));
        u.setQuit([] {});
        QSignalSpy checked(&u, &AppImageUpdater::checkDone);
        u.check();
        QVERIFY(checked.wait(10000));
        QCOMPARE(u.state(), QString("available"));
        QCOMPARE(u.version(), QString("melo 0.5.0"));
        QCOMPARE(u.notesUrl(), QString("https://example.org/releases/alpha-5"));

        u.update();
        QCOMPARE(u.state(), QString("downloading"));
        QTRY_COMPARE_WITH_TIMEOUT(u.state(), QString("ready"), 30000);
        QVERIFY(u.fetched() > 0 && u.fetched() < newFile.size() / 4);
        QCOMPARE(readFile(u.stagedPath()), newFile);
        QCOMPARE(readFile(app), oldFile);   // untouched until Restart
        QVERIFY(QFileInfo(u.stagedPath()).permissions() & QFileDevice::ExeOwner);

        u.restart();
        QVERIFY(u.relaunchPending());
        QCOMPARE(readFile(app), newFile);
        QVERIFY(!QFile::exists(u.stagedPath()));

        // the swapped-in file is the release: the next check offers nothing
        AppImageUpdater after(app);
        after.setApiUrl(QUrl(gh.base() + "/latest"));
        QSignalSpy again(&after, &AppImageUpdater::checkDone);
        after.check();
        QVERIFY(again.wait(10000));
        QCOMPARE(after.state(), QString());
    }

    void sameFileIsNoUpdate() {
        QTemporaryDir dir;
        const QByteArray file = makeElf({ { ".upd_info", updInfo("gh-releases-zsync|o|r|latest|m.zsync") } }, randomBytes(20000, 3));
        const QString app = dir.filePath("m.AppImage");
        QVERIFY(writeFile(app, file));
        Server gh;
        gh.files["m.zsync"] = makeZsync(file, 2048, 2, 2, 5, "m.AppImage", "m.AppImage");
        gh.files["latest"] = QJsonDocument(QJsonObject { { "tag_name", "alpha-4" }, { "assets", QJsonArray {
            QJsonObject { { "name", "m.zsync" }, { "browser_download_url", QString(gh.base() + "/m.zsync") } } } } }).toJson();
        AppImageUpdater u(app);
        u.setApiUrl(QUrl(gh.base() + "/latest"));
        QSignalSpy checked(&u, &AppImageUpdater::checkDone);
        u.check();
        QVERIFY(checked.wait(10000));
        QCOMPARE(u.state(), QString());
    }

    // a damaged download: the failed state with its message, nothing staged,
    // the AppImage as it was
    void updaterFailureKeepsTheAppImage() {
        QTemporaryDir dir;
        const QByteArray info = updInfo("gh-releases-zsync|o|r|latest|m.zsync");
        const QByteArray oldFile = makeElf({ { ".upd_info", info } }, makePair(2048).oldData);
        const QByteArray newFile = makeElf({ { ".upd_info", info } }, makePair(2048).newData);
        const QString app = dir.filePath("m.AppImage");
        QVERIFY(writeFile(app, oldFile));
        Server gh;
        gh.files["m.AppImage"] = newFile;
        QByteArray bad = newFile;
        for (int i = 0; i < 3000; ++i) bad[2048 * 205 + i] = char(~bad[2048 * 205 + i]);
        gh.corrupt["m.AppImage"] = bad;
        gh.files["m.zsync"] = makeZsync(newFile, 2048, 2, 2, 5, "m.AppImage", "m.AppImage");
        gh.files["latest"] = QJsonDocument(QJsonObject { { "tag_name", "alpha-5" }, { "assets", QJsonArray {
            QJsonObject { { "name", "m.zsync" }, { "browser_download_url", QString(gh.base() + "/m.zsync") } } } } }).toJson();
        AppImageUpdater u(app);
        u.setApiUrl(QUrl(gh.base() + "/latest"));
        QSignalSpy checked(&u, &AppImageUpdater::checkDone);
        u.check();
        QVERIFY(checked.wait(10000));
        u.update();
        QTRY_COMPARE_WITH_TIMEOUT(u.state(), QString("failed"), 30000);
        QCOMPARE(u.errorKind(), QString("damaged"));
        QVERIFY(!u.error().isEmpty());
        QVERIFY(!QFile::exists(u.stagedPath()));
        QCOMPARE(readFile(app), oldFile);
        // Retry fetches again: the server is fixed now
        gh.corrupt.clear();
        u.retry();
        QTRY_COMPARE_WITH_TIMEOUT(u.state(), QString("ready"), 30000);
    }

    // the new AppImage starts with melo's arguments, without the old mount's
    // environment, told to wait for the old melo's lock
    void relaunchStartsTheNewFileClean() {
        QTemporaryDir dir;
        const QString app = dir.filePath("m.AppImage"), seen = dir.filePath("seen");
        QVERIFY(writeFile(app, "#!/bin/sh\n{ echo \"args:$*\"; env; } > '" + seen.toUtf8() + "'\n"));
        QFile::setPermissions(app, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
        qputenv("APPDIR", "/tmp/.mount_old");
        qputenv("APPIMAGE", app.toUtf8());
        qputenv("GST_PLUGIN_PATH_1_0", "/tmp/.mount_old/usr/lib/gstreamer-1.0");
        // the anylinux AppRun's PATH: the mount's bin, twice, before the system's
        const QByteArray path = qgetenv("PATH");
        qputenv("PATH", "/tmp/.mount_old/bin:/tmp/.mount_old/bin:" + path);
        qputenv("MELO_TEST_LIST", "/tmp/.mount_old/share:/tmp/.mount_old/lib");
        auto restore = qScopeGuard([path] {
            qunsetenv("APPDIR"); qunsetenv("APPIMAGE"); qunsetenv("GST_PLUGIN_PATH_1_0");
            qunsetenv("MELO_TEST_LIST"); qputenv("PATH", path);
        });
        AppImageUpdater u(app);
        QVERIFY(u.relaunch());
        QTRY_VERIFY(QFileInfo(seen).size() > 0);
        QTest::qWait(100);
        const QString out = QString::fromUtf8(readFile(seen));
        QVERIFY(out.contains("MELO_UPDATE_RELAUNCH=1"));
        QVERIFY(!out.contains("APPDIR="));
        QVERIFY(!out.contains("APPIMAGE="));
        QVERIFY(!out.contains(".mount_old"));
        QVERIFY(out.contains("\nPATH=" + QString::fromLocal8Bit(path) + "\n"));
        QVERIFY(!out.contains("MELO_TEST_LIST="));
        QVERIFY(out.startsWith("args:" + QCoreApplication::arguments().mid(1).join(' ')));
    }

    // two melos (two config folders) running one AppImage: neither breaks or
    // deletes the other's update, and Restart takes only the file it verified
    void twoMelosShareOneAppImage() {
        QTemporaryDir dir;
        Release rel(dir.path());
        AppImageUpdater a(rel.app);
        QCOMPARE(checkAndUpdate(a, rel.api()), QString("ready"));
        const QString aFile = a.stagedPath();
        {
            AppImageUpdater b(rel.app);   // starting up clears only unheld files
            QVERIFY(QFile::exists(aFile));
            QCOMPARE(checkAndUpdate(b, rel.api()), QString("ready"));
            QVERIFY(b.stagedPath() != aFile);
            QCOMPARE(readFile(aFile), rel.newFile);
            QCOMPARE(readFile(b.stagedPath()), rel.newFile);
        }
        QVERIFY(QFile::exists(aFile));   // b's exit removed b's file, not a's
        QCOMPARE(updateFiles(dir.path()), QStringList { QFileInfo(aFile).fileName() });
        a.restart();
        QVERIFY(a.relaunchPending());
        QCOMPARE(readFile(rel.app), rel.newFile);
        QVERIFY(updateFiles(dir.path()).isEmpty());
    }

    // made where flock() failed: kept by other melos until it is a week old
    void anUnlockedUpdateFileIsKeptUntilOld() {
        QTemporaryDir dir;
        Release rel(dir.path());
        const QString fresh = dir.filePath(".m.AppImage.update-nolock-aaaaaa"),
                      old = dir.filePath(".m.AppImage.update-nolock-bbbbbb"),
                      stale = dir.filePath(".m.AppImage.update-cccccc");
        for (const QString& p : { fresh, old, stale }) QVERIFY(writeFile(p, "x"));
        QFile f(old);
        QVERIFY(f.open(QIODevice::ReadWrite));
        QVERIFY(f.setFileTime(QDateTime::currentDateTime().addDays(-8), QFileDevice::FileModificationTime));
        f.close();
        AppImageUpdater u(rel.app);
        QVERIFY(QFile::exists(fresh));
        QVERIFY(!QFile::exists(old));
        QVERIFY(!QFile::exists(stale));
    }

    void aSwappedUpdateFileIsRefused() {
        QTemporaryDir dir;
        Release rel(dir.path());
        AppImageUpdater u(rel.app);
        QCOMPARE(checkAndUpdate(u, rel.api()), QString("ready"));
        // another file of the same size put in its place
        QByteArray other = rel.newFile;
        other[100] = char(~other[100]);
        QVERIFY(writeFile(dir.filePath("other"), other));
        QVERIFY(::rename(QFile::encodeName(dir.filePath("other")).constData(),
                         QFile::encodeName(u.stagedPath()).constData()) == 0);
        u.restart();
        QVERIFY(!u.relaunchPending());
        QCOMPARE(u.state(), QString("failed"));
        QCOMPARE(u.errorKind(), QString("damaged"));
        QCOMPARE(readFile(rel.app), rel.oldFile);
        QCOMPARE(readFile(u.stagedPath()), other);   // not this melo's to delete
    }

    void anUpdateFileChangedInPlaceIsRefused() {
        QTemporaryDir dir;
        Release rel(dir.path());
        AppImageUpdater u(rel.app);
        QCOMPARE(checkAndUpdate(u, rel.api()), QString("ready"));
        QFile f(u.stagedPath());
        QVERIFY(f.open(QIODevice::Append));
        f.write("x");
        f.close();
        u.restart();
        QCOMPARE(u.state(), QString("failed"));
        QCOMPARE(readFile(rel.app), rel.oldFile);
    }

    void quittingMidDownloadRemovesTheFile() {
        QTemporaryDir dir;
        Release rel(dir.path());
        rel.gh.stallAfter = 1000;
        auto u = std::make_unique<AppImageUpdater>(rel.app);
        u->setApiUrl(rel.api());
        QSignalSpy checked(u.get(), &AppImageUpdater::checkDone);
        u->check();
        QVERIFY(checked.wait(10000));
        u->update();
        QCOMPARE(u->state(), QString("downloading"));
        QTRY_VERIFY(u->fetched() > 0);
        QCOMPARE(updateFiles(dir.path()).size(), 1);
        u.reset();
        QVERIFY(updateFiles(dir.path()).isEmpty());
        QCOMPARE(readFile(rel.app), rel.oldFile);
    }

    void aStalledDownloadFailsAsNetwork() {
        QTemporaryDir dir;
        Release rel(dir.path());
        rel.gh.stallAfter = 1000;
        AppImageUpdater u(rel.app);
        u.setTransferTimeout(500);
        QCOMPARE(checkAndUpdate(u, rel.api()), QString("failed"));
        QCOMPARE(u.errorKind(), QString("download"));
        QVERIFY(updateFiles(dir.path()).isEmpty());
        QCOMPARE(readFile(rel.app), rel.oldFile);
    }

    void aStalledCheckOnlyLogs() {
        QTemporaryDir dir;
        Release rel(dir.path());
        QTcpServer silent;   // accepts and never answers
        QVERIFY(silent.listen(QHostAddress::LocalHost));
        AppImageUpdater u(rel.app);
        u.setTransferTimeout(300);
        u.setApiUrl(QUrl("http://127.0.0.1:" + QString::number(silent.serverPort()) + "/latest"));
        QSignalSpy checked(&u, &AppImageUpdater::checkDone);
        u.check();
        QVERIFY(checked.wait(5000));
        QCOMPARE(u.state(), QString());
        // not stuck: the next check runs
        u.setApiUrl(rel.api());
        u.check();
        QVERIFY(checked.wait(10000));
        QCOMPARE(u.state(), QString("available"));
    }

    void anEmptyWholeAnswerFailsCleanly() {
        const Pair p = makePair(2048);
        Server s;
        s.emptyOk = true;
        s.files["new.bin"] = p.newData;
        QTemporaryDir dir;
        const QString oldPath = dir.filePath("old"), out = dir.filePath("out");
        QVERIFY(writeFile(oldPath, p.oldData));
        const auto c = zsync::parse(makeZsync(p.newData, 2048, 2, 2, 5, "new.bin", "new.bin"));
        const Run r = runJob(*c, QUrl(s.base() + "/new.bin.zsync"), oldPath, out);
        QVERIFY(!r.ok);
        QCOMPARE(r.why, ZsyncJob::Network);
        QVERIFY(!QFile::exists(out));
    }

    void anOlderReleaseIsNotOffered() {
        QTemporaryDir dir;
        Release rel(dir.path(), "alpha-4");
        AppImageUpdater u(rel.app);
        u.setCurrentVersion("0.5.0");
        QCOMPARE(checkAndUpdate(u, rel.api()), QString());
        QVERIFY(!AppImageUpdater::offered("alpha-5", "0.5.0", "aa", "bb"));
        QVERIFY(AppImageUpdater::offered("alpha-5.1", "0.5.0", "aa", "bb"));
        QVERIFY(AppImageUpdater::offered("alpha-6", "0.5.3", "aa", "bb"));
        QVERIFY(!AppImageUpdater::offered("v0.4.9", "0.5.0", "aa", "bb"));
        QVERIFY(AppImageUpdater::offered("nightly", "0.5.0", "aa", "bb"));
        QVERIFY(!AppImageUpdater::offered("nightly", "0.5.0", "aa", "aa"));
        QVERIFY(!AppImageUpdater::offered("alpha-6", "0.5.0", "aa", "aa"));
    }

    // the anylinux AppImage: melo's files are beside sharun's bin/melo, not beside
    // the loader Qt reports
    void appDirFollowsSharun() {
        QTemporaryDir dir;
        auto restore = qScopeGuard([] { qunsetenv("SHARUN_DIR"); });
        QCOMPARE(meloAppDir(), QCoreApplication::applicationDirPath());
        qputenv("SHARUN_DIR", dir.path().toUtf8());
        QCOMPARE(meloAppDir(), QCoreApplication::applicationDirPath());
        QVERIFY(QDir(dir.path()).mkpath("bin"));
        QVERIFY(writeFile(dir.filePath("bin/melo"), "x"));
        QCOMPARE(meloAppDir(), dir.path() + "/bin");
    }

    // sharun's old-kernel tracer is melo's parent and dies on TERM without
    // passing it on: melo must go with it
    void followsATracingParentOut() {
        QVERIFY(!followTracingParent());   // nothing traces the test
        int p[2], go[2];
        QVERIFY(::pipe(p) == 0 && ::pipe(go) == 0);
        const pid_t tracer = ::fork();
        if (tracer == 0) {
            ::close(p[0]);
            const pid_t app = ::fork();
            if (app == 0) {
                ::close(go[0]);
                ::signal(SIGTERM, SIG_DFL);   // not QtTest's crash handler
                if (::ptrace(PTRACE_TRACEME, 0, nullptr, nullptr) != 0) { [[maybe_unused]] auto n = ::write(p[1], "s", 1); ::_exit(0); }
                ::raise(SIGSTOP);
                const char c = followTracingParent() ? '1' : '0';
                [[maybe_unused]] auto n = ::write(p[1], &c, 1);
                ::close(go[1]);   // tells the tracer to go
                for (;;) ::pause();   // SIGTERM ends it, closing p[1]
            }
            ::close(p[1]); ::close(go[1]);
            int st = 0;
            ::waitpid(app, &st, 0);
            ::ptrace(PTRACE_CONT, app, nullptr, nullptr);
            char c;
            [[maybe_unused]] auto n = ::read(go[0], &c, 1);   // EOF once the app has answered
            ::_exit(0);   // the tracer dies; the app must follow
        }
        ::close(p[1]); ::close(go[0]); ::close(go[1]);
        char c = 0;
        QCOMPARE(::read(p[0], &c, 1), ssize_t(1));
        int st = 0;
        ::waitpid(tracer, &st, 0);
        if (c == 's') { ::close(p[0]); QSKIP("ptrace is not permitted here"); }
        QCOMPARE(c, '1');
        pollfd pf { p[0], POLLIN, 0 };
        QVERIFY(::poll(&pf, 1, 5000) == 1);
        QCOMPARE(::read(p[0], &c, 1), ssize_t(0));   // the app is gone
        ::close(p[0]);
    }

    void relaunchKeepsOnlyFlags() {
        QCOMPARE(AppImageUpdater::relaunchArgs({ "--play-pause", "https://music.youtube.com/watch?v=x",
                                                 "/home/u/song.mp3", "-v", "song.ogg" }),
                 (QStringList { "--play-pause", "-v" }));
    }

    void aSymlinkedAppImageStaysALink() {
        QTemporaryDir dir;
        QDir().mkpath(dir.filePath("real"));
        Release rel(dir.filePath("real"));
        const QString link = dir.filePath("melo.AppImage");
        QVERIFY(QFile::link(rel.app, link));
        qputenv("APPIMAGE", link.toUtf8());
        auto restore = qScopeGuard([] { qunsetenv("APPIMAGE"); });
        const QString running = AppImageUpdater::runningAppImage();
        QCOMPARE(running, QFileInfo(rel.app).canonicalFilePath());
        AppImageUpdater u(running);
        QCOMPARE(checkAndUpdate(u, rel.api()), QString("ready"));
        u.restart();
        QVERIFY(u.relaunchPending());
        QVERIFY(QFileInfo(link).isSymLink());
        QCOMPARE(readFile(link), rel.newFile);
    }

    void oversizedControlFilesAreRefused() {
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 2097152\nLength: 4000\nHash-Lengths: 2,2,4\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\n"));
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 2048\nLength: 5000000000\nHash-Lengths: 2,2,4\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\n"));
        QVERIFY(!zsync::parse("zsync: 0.6.2\nBlocksize: 1\nLength: 100000000\nHash-Lengths: 2,2,4\nURL: x\nSHA-1: 0000000000000000000000000000000000000000\n\n"));
    }

    void readOnlyFolderCannotUpdate() {
        QTemporaryDir dir;
        const QString sub = dir.filePath("ro");
        QDir().mkpath(sub);
        const QString app = sub + "/m.AppImage";
        QVERIFY(writeFile(app, makeElf({ { ".upd_info", updInfo("gh-releases-zsync|o|r|latest|m.zsync") } })));
        QFile::setPermissions(sub, QFileDevice::ReadOwner | QFileDevice::ExeOwner);
        auto restore = qScopeGuard([&] { QFile::setPermissions(sub, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner); });
        if (::access(QFile::encodeName(sub).constData(), W_OK) == 0) QSKIP("running as root");
        AppImageUpdater u(app);
        QVERIFY(u.supported());
        QVERIFY(!u.canUpdate());
    }
};

QTEST_GUILESS_MAIN(TstAppImageUpdate)
#include "tst_appimageupdate.moc"
