#pragma once
#include <QByteArray>
#include <QString>
#include <array>
#include <atomic>
#include <optional>
#include <vector>

class QFileDevice;

// zsync 0.6.2's control file and block matching (librcksum), so an AppImage
// updates by fetching only the blocks it does not already hold.
namespace zsync {

// rsync's rolling checksum as librcksum computes it: 16-bit a and b, b weighting
// the first byte by the block length.
struct Rsum { quint16 a = 0, b = 0; };
Rsum rsumBlock(const uchar* data, qsizetype len);
inline void rsumRoll(Rsum& r, uchar out, uchar in, int shift) {
    r.a = quint16(r.a + in - out);
    r.b = quint16(r.b + r.a - quint16(quint32(out) << shift));
}

struct BlockSum {
    quint16 a = 0, b = 0;            // a is already masked to what the file stores
    std::array<uchar, 16> md4 {};    // the first checksumBytes are meaningful
};

struct Control {
    QString filename;
    QString url;                     // as written: usually relative to the .zsync
    QByteArray sha1;                 // lower-case hex
    QString mtime;
    qint64 length = 0;
    int blocksize = 0;
    int blockShift = 0;
    int seqMatches = 1, rsumBytes = 4, checksumBytes = 16;
    quint16 aMask = 0xffff;
    std::vector<BlockSum> blocks;

    qint64 blockCount() const { return qint64(blocks.size()); }
    qint64 blockStart(qint64 id) const { return id << blockShift; }
    // bytes of block `id` inside the file (the last one is short)
    qint64 blockLen(qint64 id) const { return qMin<qint64>(blocksize, length - blockStart(id)); }
    bool weakMatches(qint64 id, Rsum r) const {
        const BlockSum& s = blocks[size_t(id)];
        return s.a == (r.a & aMask) && s.b == r.b;
    }
    // MD4 of one whole block (zero-padded past the end) against the table
    bool strongMatches(qint64 id, const uchar* block) const;
};

// What melo accepts: 1 MB blocks, a 4 GB file, 8 M blocks (a 160 MB table).
constexpr int kMaxBlocksize = 1 << 20;
constexpr qint64 kMaxLength = qint64(4) << 30;
constexpr qint64 kMaxBlocks = qint64(1) << 23;
// a control file is at most 16 MB (a 4 GB file at melo's 2048-byte blocks is 14 MB)
constexpr qint64 kMaxControlBytes = qint64(16) << 20;

// The header lines and the block table. Empty with `error` set when the file is
// not one zsync 0.6.2 would accept.
std::optional<Control> parse(const QByteArray& bytes, QString* error = nullptr);

// Matches `sourcePath` against the table and writes every block it finds into
// `out` at the block's place in the new file. `have` is sized to the block count
// and marks what was written. False on a read or write error, or when cancelled.
bool scan(const Control& c, const QString& sourcePath, QFileDevice& out,
          std::vector<char>& have, const std::atomic<bool>* cancel = nullptr,
          QString* error = nullptr);

// Inclusive block ranges still missing; gaps of at most `mergeGap` known blocks
// are fetched with their neighbours so one request covers both.
std::vector<std::pair<qint64, qint64>> missingRanges(const std::vector<char>& have, qint64 mergeGap = 0);

}   // namespace zsync
