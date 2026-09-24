#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

// Read-only ZIP access, central-directory based, stored (0) and deflate (8).
// Every offset and length from the archive is attacker-chosen and checked
// against the real file size before use; a malformed archive leaves isValid()
// false with errorString() set, never throws, and never allocates on a size the
// archive asked for.
// Immutable after construction, so read() is safe from several threads (QML's
// image loader thread reaches it via Image.asynchronous). The whole file is
// held in memory (see kMaxArchiveBytes).
class ZipReader {
public:
    // Hard limits on untrusted input: the archive we will map, and the single
    // entry we will inflate.
    static constexpr qint64 kMaxArchiveBytes = 64LL << 20;
    static constexpr qint64 kMaxEntryBytes = 64LL << 20;

    // Bytes in; there must be no path constructor. melo opens the file itself
    // with O_NOFOLLOW and verifies the descriptor against the plugin's data root.
    // A path would be reopened by name, and the plugin's sidecar (manager.ts grants
    // --allow-fs-write over its data dir) could re-point it between check and open.
    // Nothing here stores or prints a path.
    explicit ZipReader(QByteArray bytes);

    bool isValid() const { return valid_; }

    // Why the archive was rejected. Set during construction and never after,
    // so it describes the archive and nothing else — empty whenever
    // isValid() is true, no matter what has been read since.
    QString errorString() const { return error_; }

    // Entry names in central-directory order, exactly as stored.
    QStringList entryNames() const;

    // Case-insensitive. Empty on any failure: absent name, unsupported
    // compression, corrupt payload, bad CRC. An entry that is absent and one
    // that is unreadable are the same answer here on purpose — callers probe
    // for optional skin files and must not have to tell the two apart.
    QByteArray read(const QString& name) const;

private:
    struct Entry {
        QString name;
        quint16 method = 0;
        quint32 crc = 0;
        qint64 compressedSize = 0;
        qint64 uncompressedSize = 0;
        qint64 dataOffset = 0;   // payload start, past the local file header
    };

    void finish(bool ok);
    bool parseBuffer();
    QByteArray inflateRaw(const Entry& e) const;

    QByteArray buf_;
    QList<Entry> entries_;
    QHash<QString, int> index_;   // folded name -> index into entries_
    QString error_;
    bool valid_ = false;
};
