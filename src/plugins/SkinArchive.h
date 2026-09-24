#pragma once

#include <QHash>
#include <QImage>
#include <QString>
#include <QStringList>

#include <memory>

// A Winamp .wsz decoded once, in full, and never mutated.
//
// SkinImageProvider reads it on Qt's image loader thread (plugin QML sets
// Image.asynchronous), so every field is written in load() before the object
// escapes and callers only get shared_ptr<const SkinArchive>. A new skin is a
// new archive, so the read path needs no lock.
//
// Lookup is case-folded, and when every entry shares a leading directory
// ("1/Main.bmp" in a zipped folder) that prefix is stripped from every key.
// Stripping a prefix all names carry is injective, so it creates no
// collisions; basename matching would, and would need a directory-order
// tie-break. The prefix is a whole directory path ("1/" and "10/" share none).
// When stray root entries (__MACOSX/, Thumbs.db) leave no common prefix, the
// folder of the only main.bmp is used if stripping it collides with nothing.
// Separators are '/' only, as the zip format specifies.
//
// A key is only a QHash key: never joined to a directory, opened or
// normalised ("1/../main.bmp" is a literal name). The archive is untrusted
// input and none of its names is treated as a path.
class SkinArchive {
public:
    // Ceiling on everything load() keeps decoded, summed across entries.
    // ZipReader caps each entry at 64 MB but not the total, and compressible
    // images inflate far past their stored size. Same 64 MiB as ZipReader's
    // per-entry cap; a real skin decodes to about 2.3 MB. Peak residency is this
    // plus one entry.
    static constexpr qint64 kMaxDecodedBytes = 64LL << 20;
    // Refused from the header, before any pixels are produced. The largest
    // real Winamp skin sprite sheet is a few hundred KB of pixels; 64
    // megapixels is four orders of magnitude of headroom and still bounds a
    // decode bomb at a size that cannot take the GUI thread away for hours.
    static constexpr qint64 kMaxImagePixels = 64LL << 20;

    // Bytes in, archive out; there is no path overload. A path would be
    // reopened by name, and the plugin's sidecar can re-point it between check
    // and open (manager.ts grants --allow-fs-write over its data dir), so callers
    // read through a verified descriptor (MeloUiArchives::readVerifiedFile()).
    // `label` is the only caller-supplied string that can reach *error, so it
    // must be fit to show a plugin, never an absolute path.
    // Null, with the reason in *error, when the archive is unusable as a whole
    // (not a zip, hostile offsets); a non-null return is fully loaded. Entries
    // that are absent, use an unsupported method, are corrupt, or fall past
    // kMaxDecodedBytes are left out of the maps.
    static std::shared_ptr<const SkinArchive> load(QByteArray bytes,
                                                   const QString& label,
                                                   QString* error = nullptr);

    // Every entry the directory listed, in order, named as stored (prefix kept),
    // including entries that failed to decode. One shape breaks the round trip:
    // with "1/main.bmp" and "1/1/main.bmp" both present, both names resolve to the
    // inner sheet and the outer one answers only to "main.bmp".
    QStringList names() const { return names_; }

    // Null when the entry is absent, is not an image entry, or did not decode.
    QImage image(const QString& name) const { return lookup(images_, name); }

    // Empty when the entry is absent or is an image entry. UTF-8 where that
    // decodes, Latin-1 otherwise — pledit.txt and readme.txt in the wild are
    // not reliably either.
    QString text(const QString& name) const { return lookup(texts_, name); }

private:
    SkinArchive() = default;

    // The key an ENTRY is stored under: lower case, then the archive's own
    // shared leading directory removed if the name carries it. Not static: the
    // prefix is a property of this archive.
    QString fold(const QString& name) const {
        const QString lower = name.toLower();
        // An empty prefix_ makes this the identity, which is the ordinary case:
        // only a zipped-folder skin has one.
        return lower.startsWith(prefix_) ? lower.mid(prefix_.size()) : lower;
    }

    // Exact name first, then stripped: with "1/main.bmp" beside "1/1/main.bmp"
    // (stored as "main.bmp" and "1/main.bmp"), strip-first would answer
    // "1/main.bmp" with the outer sheet and leave the inner one unreachable.
    // Keys are unique, so the order is unambiguous.
    template <typename T>
    T lookup(const QHash<QString, T>& from, const QString& name) const {
        const QString lower = name.toLower();
        const auto exact = from.constFind(lower);
        if (exact != from.cend()) return *exact;
        if (prefix_.isEmpty() || !lower.startsWith(prefix_)) return {};
        return from.value(lower.mid(prefix_.size()));
    }

    QStringList names_;
    // Folded, with its trailing '/', or empty. Written in load() like every
    // other field, before the archive is visible to anyone.
    QString prefix_;
    QHash<QString, QImage> images_;
    QHash<QString, QString> texts_;
};
