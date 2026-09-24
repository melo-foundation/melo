#include "ZipReader.h"

#include <zlib.h>

#include <utility>

namespace {

constexpr qint64 kEocdSize = 22;         // without the trailing comment
constexpr qint64 kMaxComment = 65535;    // the comment length field is 16 bit
constexpr qint64 kCdhSize = 46;          // central directory header, fixed part
constexpr qint64 kLfhSize = 30;          // local file header, fixed part
constexpr qint64 kInflateChunk = 64 * 1024;

quint16 le16(const char* p) {
    return quint16(quint8(p[0])) | quint16(quint8(p[1])) << 8;
}

quint32 le32(const char* p) {
    return quint32(quint8(p[0])) | quint32(quint8(p[1])) << 8
         | quint32(quint8(p[2])) << 16 | quint32(quint8(p[3])) << 24;
}

// Does [off, off+len) lie inside [0, size)? Written as a subtraction so no
// addition of two archive-supplied 32-bit values can wrap.
bool fits(qint64 off, qint64 len, qint64 size) {
    return off >= 0 && len >= 0 && off <= size && len <= size - off;
}

bool hasSignature(const char* p, quint8 a, quint8 b) {
    return p[0] == 'P' && p[1] == 'K' && quint8(p[2]) == a && quint8(p[3]) == b;
}

}   // namespace

ZipReader::ZipReader(QByteArray bytes) {
    buf_ = std::move(bytes);
    finish(parseBuffer());
}

void ZipReader::finish(bool ok) {
    valid_ = ok;
    if (valid_) return;
    buf_.clear();
    entries_.clear();
    index_.clear();
    if (error_.isEmpty()) error_ = QStringLiteral("malformed zip archive");
}

QStringList ZipReader::entryNames() const {
    QStringList out;
    out.reserve(entries_.size());
    for (const Entry& e : entries_) out.append(e.name);
    return out;
}

bool ZipReader::parseBuffer() {
    // The bound every offset below is validated against, checked here because
    // this is the one place every construction passes through.
    if (buf_.size() > kMaxArchiveBytes) {
        error_ = QStringLiteral("archive is %1 bytes, over the %2 byte limit")
                     .arg(buf_.size())
                     .arg(kMaxArchiveBytes);
        return false;
    }
    if (buf_.size() < kEocdSize) {
        error_ = QStringLiteral("file is %1 bytes, too small to be a zip archive")
                     .arg(buf_.size());
        return false;
    }

    const qint64 n = buf_.size();
    const char* d = buf_.constData();

    // End of central directory. Its trailing comment is at most 65535 bytes, so
    // the scan stops there. The last record whose comment length reaches exactly
    // the end of the file wins, so a stray signature in compressed data is skipped.
    qint64 eocd = -1;
    const qint64 lowest = qMax<qint64>(0, n - kEocdSize - kMaxComment);
    for (qint64 i = n - kEocdSize; i >= lowest; --i) {
        if (!hasSignature(d + i, 5, 6)) continue;
        if (i + kEocdSize + qint64(le16(d + i + 20)) == n) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        error_ = QStringLiteral("no end-of-central-directory record in the last "
                                "%1 bytes")
                     .arg(qMin(n, kEocdSize + kMaxComment));
        return false;
    }

    const quint16 thisDisk = le16(d + eocd + 4);
    const quint16 cdDisk = le16(d + eocd + 6);
    const quint16 entriesHere = le16(d + eocd + 8);
    const quint16 entriesTotal = le16(d + eocd + 10);
    const quint32 cdSize = le32(d + eocd + 12);
    const quint32 cdOffset = le32(d + eocd + 16);

    if (thisDisk != 0 || cdDisk != 0 || entriesHere != entriesTotal) {
        error_ = QStringLiteral("split archives are not supported");
        return false;
    }
    if (entriesTotal == 0xFFFF || cdSize == 0xFFFFFFFFu
        || cdOffset == 0xFFFFFFFFu) {
        error_ = QStringLiteral("zip64 archives are not supported");
        return false;
    }
    if (!fits(cdOffset, cdSize, n)) {
        error_ = QStringLiteral("central directory at %1 + %2 runs past the "
                                "end of a %3 byte file")
                     .arg(cdOffset)
                     .arg(cdSize)
                     .arg(n);
        return false;
    }

    const qint64 cdEnd = qint64(cdOffset) + cdSize;
    qint64 pos = cdOffset;
    // The count is still just a claim at this point; the smallest possible
    // entry is one 46-byte header with a one-byte name, so reserve for what
    // the directory could actually hold, not for what it says.
    entries_.reserve(int(qMin<qint64>(entriesTotal, cdSize / (kCdhSize + 1) + 1)));

    for (int i = 0; i < entriesTotal; ++i) {
        if (!fits(pos, kCdhSize, cdEnd)) {
            error_ = QStringLiteral("central directory ends after %1 of %2 "
                                    "entries")
                         .arg(i)
                         .arg(entriesTotal);
            return false;
        }
        const char* h = d + pos;
        if (!hasSignature(h, 1, 2)) {
            error_ = QStringLiteral("bad central directory header for entry %1")
                         .arg(i);
            return false;
        }

        const quint16 flags = le16(h + 8);
        const quint16 nameLen = le16(h + 28);
        const quint16 extraLen = le16(h + 30);
        const quint16 commentLen = le16(h + 32);
        const quint16 startDisk = le16(h + 34);
        const qint64 varLen = qint64(nameLen) + extraLen + commentLen;

        if (!fits(pos + kCdhSize, varLen, cdEnd)) {
            error_ = QStringLiteral("entry %1 header runs past the central "
                                    "directory")
                         .arg(i);
            return false;
        }
        if (startDisk != 0) {
            error_ = QStringLiteral("split archives are not supported");
            return false;
        }
        if (nameLen == 0) {
            error_ = QStringLiteral("entry %1 has an empty name").arg(i);
            return false;
        }

        const QByteArray rawName(h + kCdhSize, nameLen);
        if (rawName.contains('\0')) {
            error_ = QStringLiteral("entry %1 name contains a NUL byte").arg(i);
            return false;
        }

        Entry e;
        // Bit 11 is the only in-band signal that the name is UTF-8. Everything
        // else predates it; Latin-1 at least never fails to decode.
        e.name = (flags & 0x0800) ? QString::fromUtf8(rawName)
                                  : QString::fromLatin1(rawName);
        e.method = le16(h + 10);
        e.crc = le32(h + 16);
        e.compressedSize = le32(h + 20);
        e.uncompressedSize = le32(h + 24);

        if (e.compressedSize > kMaxEntryBytes
            || e.uncompressedSize > kMaxEntryBytes) {
            error_ = QStringLiteral("entry \"%1\" declares %2 -> %3 bytes, "
                                    "over the %4 byte limit")
                         .arg(e.name)
                         .arg(e.compressedSize)
                         .arg(e.uncompressedSize)
                         .arg(kMaxEntryBytes);
            return false;
        }
        if (e.method == 0 && e.compressedSize != e.uncompressedSize) {
            error_ = QStringLiteral("stored entry \"%1\" declares %2 bytes "
                                    "compressed and %3 uncompressed")
                         .arg(e.name)
                         .arg(e.compressedSize)
                         .arg(e.uncompressedSize);
            return false;
        }

        // The local file header carries its own name and extra lengths, which
        // need not match the ones above, so the payload offset can only be
        // resolved here. Everything it implies is checked against the file.
        const qint64 local = le32(h + 42);
        if (!fits(local, kLfhSize, n)) {
            error_ = QStringLiteral("entry \"%1\" puts its local header at %2, "
                                    "past the end of a %3 byte file")
                         .arg(e.name)
                         .arg(local)
                         .arg(n);
            return false;
        }
        const char* lh = d + local;
        if (!hasSignature(lh, 3, 4)) {
            error_ = QStringLiteral("bad local file header for entry \"%1\"")
                         .arg(e.name);
            return false;
        }
        const qint64 localVar = qint64(le16(lh + 26)) + le16(lh + 28);
        if (!fits(local + kLfhSize, localVar, n)) {
            error_ = QStringLiteral("local header of entry \"%1\" runs past "
                                    "the end of the file")
                         .arg(e.name);
            return false;
        }
        e.dataOffset = local + kLfhSize + localVar;
        if (!fits(e.dataOffset, e.compressedSize, n)) {
            error_ = QStringLiteral("entry \"%1\" data at %2 + %3 runs past "
                                    "the end of a %4 byte file")
                         .arg(e.name)
                         .arg(e.dataOffset)
                         .arg(e.compressedSize)
                         .arg(n);
            return false;
        }

        entries_.append(e);
        // First writer wins, so a duplicate name appended later cannot shadow
        // the entry the directory listed first.
        const QString key = e.name.toLower();
        if (!index_.contains(key)) index_.insert(key, entries_.size() - 1);

        pos += kCdhSize + varLen;
    }

    return true;
}

// Nothing on this path writes to the object. read() is const in fact and not
// only in signature, which is what lets a built reader be shared across
// threads; every failure is reported by returning nothing.
QByteArray ZipReader::read(const QString& name) const {
    if (!valid_) return {};

    const int idx = index_.value(name.toLower(), -1);
    if (idx < 0) return {};
    const Entry& e = entries_.at(idx);

    // parseBuffer() proved this, but the read path is the one an attacker reaches
    // repeatedly; re-checking here costs two comparisons.
    if (!fits(e.dataOffset, e.compressedSize, buf_.size())) return {};

    if (e.method == 0) {
        QByteArray out = buf_.mid(e.dataOffset, e.compressedSize);
        const quint32 crc = ::crc32(::crc32(0L, Z_NULL, 0),
                                    reinterpret_cast<const Bytef*>(out.constData()),
                                    uInt(out.size()));
        if (crc != e.crc) return {};
        return out;
    }
    if (e.method != 8) return {};   // not corruption, just a gap in us
    return inflateRaw(e);
}

QByteArray ZipReader::inflateRaw(const Entry& e) const {
    z_stream s = {};
    if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return {};
    s.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(buf_.constData())
                                         + e.dataOffset);
    s.avail_in = uInt(e.compressedSize);

    // Output grows a chunk at a time and stops at the declared size, which
    // parseBuffer() already capped. Sizing a buffer from the header up front would
    // let a 200 byte archive ask for 64 MB.
    QByteArray out;
    QByteArray chunk(kInflateChunk, Qt::Uninitialized);
    for (;;) {
        s.next_out = reinterpret_cast<Bytef*>(chunk.data());
        s.avail_out = uInt(chunk.size());
        const int ret = ::inflate(&s, Z_NO_FLUSH);
        const qint64 produced = chunk.size() - qint64(s.avail_out);

        if (produced > 0) {
            // inflating past the declared size: a bomb, or a lying header
            if (produced > e.uncompressedSize - out.size()) {
                inflateEnd(&s);
                return {};
            }
            out.append(chunk.constData(), produced);
        }

        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK) {   // corrupt or truncated stream
            inflateEnd(&s);
            return {};
        }
        // Z_OK with nothing consumed and nothing produced cannot recur; bail
        // rather than trust that, so the loop can never spin.
        if (produced == 0 && s.avail_in == 0) {
            inflateEnd(&s);
            return {};
        }
    }
    inflateEnd(&s);

    if (out.size() != e.uncompressedSize) return {};
    const quint32 crc = ::crc32(::crc32(0L, Z_NULL, 0),
                                reinterpret_cast<const Bytef*>(out.constData()),
                                uInt(out.size()));
    if (crc != e.crc) return {};
    return out;
}
