#include "Zsync.h"

#include <QCryptographicHash>
#include <QFile>
#include <algorithm>
#include <cstring>
#include <new>

namespace zsync {

Rsum rsumBlock(const uchar* data, qsizetype len) {
    quint16 a = 0, b = 0;
    for (qsizetype n = len; n > 0; --n) {
        const uchar c = *data++;
        a = quint16(a + c);
        b = quint16(b + quint32(n) * c);
    }
    return { a, b };
}

bool Control::strongMatches(qint64 id, const uchar* block) const {
    const QByteArray h = QCryptographicHash::hash(
        QByteArrayView(reinterpret_cast<const char*>(block), blocksize), QCryptographicHash::Md4);
    return std::memcmp(h.constData(), blocks[size_t(id)].md4.data(), size_t(checksumBytes)) == 0;
}

std::optional<Control> parse(const QByteArray& bytes, QString* error) {
    auto fail = [error](const QString& why) -> std::optional<Control> {
        if (error) *error = why;
        return std::nullopt;
    };
    Control c;
    qsizetype pos = 0;
    bool sawVersion = false;
    for (;;) {
        const qsizetype nl = bytes.indexOf('\n', pos);
        if (nl < 0) return fail(QStringLiteral("no end to the header"));
        QByteArray line = bytes.mid(pos, nl - pos);
        pos = nl + 1;
        while (line.endsWith('\r') || line.endsWith(' ')) line.chop(1);
        if (line.isEmpty()) break;
        const qsizetype colon = line.indexOf(": ");
        if (colon <= 0) return fail(QStringLiteral("bad header line"));
        const QByteArray key = line.left(colon);
        const QByteArray val = line.mid(colon + 2);
        if (key == "zsync") {
            if (val == "0.0.4") return fail(QStringLiteral("zsync 0.0.4 files are not supported"));
            sawVersion = true;
        } else if (key == "Filename") c.filename = QString::fromUtf8(val);
        else if (key == "MTime") c.mtime = QString::fromUtf8(val);
        else if (key == "Length") c.length = val.toLongLong();
        else if (key == "URL") { if (c.url.isEmpty()) c.url = QString::fromUtf8(val); }
        else if (key == "SHA-1") {
            if (val.size() != 40) return fail(QStringLiteral("SHA-1 is not 40 hex digits"));
            c.sha1 = val.toLower();
        } else if (key == "Blocksize") {
            c.blocksize = val.toInt();
            if (c.blocksize <= 0 || c.blocksize > kMaxBlocksize || (c.blocksize & (c.blocksize - 1)))
                return fail(QStringLiteral("block size is not a power of two up to 1 MB"));
        } else if (key == "Hash-Lengths") {
            const QList<QByteArray> p = val.split(',');
            if (p.size() != 3) return fail(QStringLiteral("bad Hash-Lengths"));
            c.seqMatches = p[0].toInt(); c.rsumBytes = p[1].toInt(); c.checksumBytes = p[2].toInt();
            if (c.rsumBytes < 1 || c.rsumBytes > 4 || c.checksumBytes < 3 || c.checksumBytes > 16
                    || c.seqMatches < 1 || c.seqMatches > 2)
                return fail(QStringLiteral("bad Hash-Lengths"));
        }
        // Z-* (gzip recompression) and other tags: the file itself is all melo fetches
    }
    if (!sawVersion) return fail(QStringLiteral("not a zsync file"));
    if (c.length <= 0 || c.blocksize <= 0) return fail(QStringLiteral("no Length or Blocksize"));
    if (c.length > kMaxLength) return fail(QStringLiteral("Length over 4 GB"));
    if (c.url.isEmpty()) return fail(QStringLiteral("no URL"));
    if (c.sha1.isEmpty()) return fail(QStringLiteral("no SHA-1"));
    while ((1 << c.blockShift) < c.blocksize) ++c.blockShift;
    c.aMask = c.rsumBytes < 3 ? 0 : c.rsumBytes == 3 ? 0xff : 0xffff;

    const qint64 n = (c.length + c.blocksize - 1) / c.blocksize;
    if (n > kMaxBlocks) return fail(QStringLiteral("too many blocks"));
    const qint64 per = c.rsumBytes + c.checksumBytes;
    if (bytes.size() - pos < n * per) return fail(QStringLiteral("block table is short"));
    try {
        c.blocks.resize(size_t(n));
    } catch (const std::bad_alloc&) {
        return fail(QStringLiteral("out of memory"));
    }
    const uchar* p = reinterpret_cast<const uchar*>(bytes.constData()) + pos;
    for (qint64 id = 0; id < n; ++id, p += per) {
        // the trailing rsumBytes of a then b, both big-endian
        uchar r[4] = { 0, 0, 0, 0 };
        std::memcpy(r + 4 - c.rsumBytes, p, size_t(c.rsumBytes));
        BlockSum& s = c.blocks[size_t(id)];
        s.a = quint16((r[0] << 8 | r[1]) & c.aMask);
        s.b = quint16(r[2] << 8 | r[3]);
        std::memcpy(s.md4.data(), p + c.rsumBytes, size_t(c.checksumBytes));
    }
    return c;
}

namespace {

// The rsum of a window keyed as librcksum's hash is: b, then the next block's b
// when two in a row must match, else a.
inline quint32 keyOf(const Control& c, Rsum r0, Rsum r1) {
    return quint32(r0.b) << 16 | (c.seqMatches > 1 ? r1.b : quint16(r0.a & c.aMask));
}
inline quint32 bucketOf(quint32 key) { return (key * 0x9E3779B1u) >> 12; }   // 2^20 bits

// The source as one padded view: a mapped file plus a copy of its tail followed
// by zeros, so every window of up to `context` bytes is contiguous.
struct Source {
    const uchar* map = nullptr;
    qint64 size = 0, split = 0;
    QByteArray tail;
    const uchar* at(qint64 i, qint64 len) const {
        return i + len <= size ? map + i : reinterpret_cast<const uchar*>(tail.constData()) + (i - split);
    }
};

}   // namespace

bool scan(const Control& c, const QString& sourcePath, QFileDevice& out,
          std::vector<char>& have, const std::atomic<bool>* cancel, QString* error) {
    const qint64 n = c.blockCount();
    have.assign(size_t(n), 0);
    QFile f(sourcePath);
    if (!f.open(QIODevice::ReadOnly)) { if (error) *error = f.errorString(); return false; }
    const qint64 bs = c.blocksize;
    const qint64 context = bs * c.seqMatches;

    Source src;
    src.size = f.size();
    QByteArray whole;
    if (src.size > 0) {
        src.map = f.map(0, src.size);
        if (!src.map) {
            whole = f.readAll();
            if (whole.size() != src.size) { if (error) *error = f.errorString(); return false; }
            src.map = reinterpret_cast<const uchar*>(whole.constData());
        }
    }
    src.split = qMax<qint64>(0, src.size - 2 * context);
    src.tail = QByteArray(reinterpret_cast<const char*>(src.map) + src.split, src.size - src.split);
    src.tail.append(QByteArray(context, '\0'));

    // the table, sorted by key, behind a bit filter for the common miss
    std::vector<std::pair<quint32, qint64>> table;
    table.reserve(size_t(n));
    std::vector<quint64> filter((1u << 20) / 64, 0);
    for (qint64 id = 0; id < n; ++id) {
        const BlockSum& s = c.blocks[size_t(id)];
        // the block after the last is the zero padding past the end
        const quint16 nextB = id + 1 < n ? c.blocks[size_t(id + 1)].b : 0;
        const quint32 key = quint32(s.b) << 16 | (c.seqMatches > 1 ? nextB : s.a);
        table.emplace_back(key, id);
        const quint32 h = bucketOf(key);
        filter[h >> 6] |= quint64(1) << (h & 63);
    }
    std::sort(table.begin(), table.end());

    auto write = [&](qint64 id, const uchar* data) {
        if (have[size_t(id)]) return true;
        if (!out.seek(c.blockStart(id))) return false;
        const qint64 len = c.blockLen(id);
        if (out.write(reinterpret_cast<const char*>(data), len) != len) return false;
        have[size_t(id)] = 1;
        return true;
    };
    auto writeFailed = [&] { if (error) *error = out.errorString(); return false; };

    const int shift = c.blockShift;
    qint64 x = 0;
    qint64 nextMatch = -1;   // after a run of matches, the block expected next
    Rsum r0, r1;
    auto recompute = [&] {
        r0 = rsumBlock(src.at(x, bs), bs);
        if (c.seqMatches > 1) r1 = rsumBlock(src.at(x + bs, bs), bs);
    };
    if (src.size > 0) recompute();
    while (x < src.size) {
        if (cancel && cancel->load(std::memory_order_relaxed)) { if (error) *error = QStringLiteral("cancelled"); return false; }
        int advance = 0;
        if (nextMatch >= 0 && c.seqMatches > 1) {
            if (nextMatch < n && !have[size_t(nextMatch)] && c.weakMatches(nextMatch, r0)
                    && c.strongMatches(nextMatch, src.at(x, bs))) {
                if (!write(nextMatch, src.at(x, bs))) return writeFailed();
                ++nextMatch;
                advance = 1;
            } else {
                nextMatch = -1;
            }
        }
        if (!advance) {
            const quint32 key = keyOf(c, r0, r1);
            const quint32 h = bucketOf(key);
            if (filter[h >> 6] >> (h & 63) & 1) {
                auto it = std::lower_bound(table.begin(), table.end(), std::make_pair(key, qint64(-1)));
                bool md4Done[2] = { false, false };
                QByteArray md4[2];
                auto strong = [&](int k, qint64 id) {
                    if (!md4Done[k]) {
                        md4[k] = QCryptographicHash::hash(
                            QByteArrayView(reinterpret_cast<const char*>(src.at(x + k * bs, bs)), bs),
                            QCryptographicHash::Md4);
                        md4Done[k] = true;
                    }
                    return std::memcmp(md4[k].constData(), c.blocks[size_t(id)].md4.data(),
                                       size_t(c.checksumBytes)) == 0;
                };
                for (; it != table.end() && it->first == key; ++it) {
                    const qint64 id = it->second;
                    if (have[size_t(id)]) continue;
                    if (!c.weakMatches(id, r0)) continue;
                    const bool pair = c.seqMatches > 1 && id + 1 < n;
                    if (pair && !c.weakMatches(id + 1, r1)) continue;
                    if (!strong(0, id)) continue;
                    if (pair && !strong(1, id + 1)) continue;
                    if (!write(id, src.at(x, bs))) return writeFailed();
                    if (pair && !write(id + 1, src.at(x + bs, bs))) return writeFailed();
                    advance = c.seqMatches;
                    nextMatch = id + c.seqMatches;
                }
            }
        }
        if (advance) {
            x += advance * bs;
            if (x >= src.size) break;
            if (c.seqMatches > 1 && advance == 1) {
                r0 = r1;
                r1 = rsumBlock(src.at(x + bs, bs), bs);
            } else {
                recompute();
            }
            continue;
        }
        // roll the window one byte
        const uchar oc = *src.at(x, 1);
        const uchar nc = *src.at(x + bs, 1);
        rsumRoll(r0, oc, nc, shift);
        if (c.seqMatches > 1) rsumRoll(r1, nc, *src.at(x + 2 * bs, 1), shift);
        ++x;
    }
    return true;
}

std::vector<std::pair<qint64, qint64>> missingRanges(const std::vector<char>& have, qint64 mergeGap) {
    std::vector<std::pair<qint64, qint64>> out;
    const qint64 n = qint64(have.size());
    for (qint64 i = 0; i < n;) {
        if (have[size_t(i)]) { ++i; continue; }
        qint64 j = i;
        while (j + 1 < n && !have[size_t(j + 1)]) ++j;
        if (!out.empty() && i - out.back().second - 1 <= mergeGap) out.back().second = j;
        else out.emplace_back(i, j);
        i = j + 1;
    }
    return out;
}

}   // namespace zsync
