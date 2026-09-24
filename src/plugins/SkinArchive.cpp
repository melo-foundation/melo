#include "SkinArchive.h"
#include <QImageReader>
#include <QBuffer>

#include "ZipReader.h"

#include <QByteArray>
#include <QSet>
#include <QStringDecoder>

#include <utility>

namespace {

// Which decoder an entry goes to is decided by its name, not by sniffing every
// blob in the archive against every image handler Qt happens to have loaded.
// The bytes are still content-detected within the image path, so a PNG some
// skin author saved as .bmp — which does happen — still decodes.
bool isImageName(const QString& name) {
    static const QSet<QString> kImageSuffixes = {
        QStringLiteral("bmp"), QStringLiteral("png"), QStringLiteral("gif"),
        QStringLiteral("jpg"), QStringLiteral("jpeg"), QStringLiteral("cur"),
        QStringLiteral("ico"),
    };
    const qsizetype dot = name.lastIndexOf(QLatin1Char('.'));
    if (dot < 0) return false;
    return kImageSuffixes.contains(name.mid(dot + 1).toLower());
}

// load() runs synchronously on the GUI thread (MeloUiArchives::reload), so
// names are folded once here rather than inside the nested prefix loops, where
// a deep, late-diverging archive would make it O(depth x entries x length).
QStringList foldedNames(const QStringList& names) {
    QStringList out;
    out.reserve(names.size());
    for (const QString& n : names) out.append(n.toLower());
    return out;
}

// The longest leading directory path every entry shares, with its trailing
// '/'; empty when they share none (see SkinArchive.h). Stripping a prefix all
// names carry cannot create duplicate keys. The common string prefix is cut
// back to its last '/' so "1/main.bmp" and "10/main.bmp" share nothing.
QString commonDirectory(const QStringList& folded) {
    if (folded.isEmpty()) return {};
    QString prefix = folded.constFirst();
    for (const QString& n : folded) {
        qsizetype i = 0;
        const qsizetype max = qMin(prefix.size(), n.size());
        while (i < max && prefix.at(i) == n.at(i)) ++i;
        prefix.truncate(i);
        if (prefix.isEmpty()) return {};
    }
    prefix.truncate(prefix.lastIndexOf(QLatin1Char('/')) + 1);
    return prefix;
}

// The folder holding the archive's only main.bmp, used when commonDirectory()
// finds none because of a stray root entry (__MACOSX/, Thumbs.db, a readme).
// Two main.bmp entries mean two candidate skins, so nothing is stripped rather
// than picking by directory order. This prefix is not on every name, so it is
// used only if the stripped key set has no duplicate.
QString skinDirectory(const QStringList& folded) {
    QString candidate;
    int found = 0;
    for (const QString& n : folded) {
        if (!n.endsWith(QLatin1String("/main.bmp"))) continue;
        if (++found > 1) return {};         // ambiguous: two candidate skins
        candidate = n.left(n.size() - 8);   // keep the trailing '/'
    }
    if (candidate.isEmpty()) return {};
    QSet<QString> keys;
    for (const QString& n : folded) {
        const QString key = n.startsWith(candidate) ? n.mid(candidate.size()) : n;
        if (key.isEmpty()) continue;        // folder entries carry nothing
        if (keys.contains(key)) return {};  // two entries would claim one name
        keys.insert(key);
    }
    return candidate;
}

// UTF-8 when the whole entry is valid UTF-8, else Latin-1, which cannot fail.
// Stateless, so a multi-byte sequence cut off at the end counts as invalid.
QString decodeText(const QByteArray& bytes) {
    QStringDecoder utf8(QStringDecoder::Utf8, QStringDecoder::Flag::Stateless);
    QString out = utf8(bytes);
    if (utf8.hasError()) return QString::fromLatin1(bytes);
    return out;
}

}   // namespace

std::shared_ptr<const SkinArchive> SkinArchive::load(QByteArray bytes,
                                                     const QString& label,
                                                     QString* error) {
    if (error) error->clear();

    const ZipReader zip(std::move(bytes));
    if (!zip.isValid()) {
        // The label is the CALLER's, and the reader's own messages carry no
        // path because the reader was never given one. Nothing that lands in
        // *error can name a filesystem location the caller did not choose to
        // disclose — which is what lets this string be shown to a plugin.
        if (error) *error = QStringLiteral("%1: %2").arg(label, zip.errorString());
        return {};
    }

    // Built through a mutable pointer that never escapes this function, so the
    // const archive the caller gets is complete the first time anyone sees it.
    std::shared_ptr<SkinArchive> a(new SkinArchive);
    a->names_ = zip.entryNames();
    // Before the first fold(): every key is measured against this prefix. The
    // main.bmp fallback runs only when the whole-archive rule finds nothing, so it
    // never widens the injective primary rule.
    {
        const QStringList folded = foldedNames(a->names_);
        a->prefix_ = commonDirectory(folded);
        if (a->prefix_.isEmpty()) a->prefix_ = skinDirectory(folded);
    }
    a->images_.reserve(a->names_.size());

    qint64 decoded = 0;
    for (const QString& name : std::as_const(a->names_)) {
        // Checked before each decode, so the peak is the budget plus one entry.
        // Entries past it stay listed but undecoded, like any unreadable entry.
        if (decoded >= kMaxDecodedBytes) break;

        const QString key = a->fold(name);
        // The archive's own folder entry ("1/") folds to nothing once the
        // prefix comes off. It carries no bytes and would be skipped below in
        // any case; dropping it here is what keeps an empty key out of the maps
        // rather than leaving that to a property of the zip.
        if (key.isEmpty()) continue;
        // First entry of a name wins, matching ZipReader's own index, so a
        // duplicate appended later cannot shadow it. Prefix stripping is
        // injective (SkinArchive.h), so it adds no duplicates for this to
        // arbitrate.
        if (a->images_.contains(key) || a->texts_.contains(key)) continue;

        // Empty covers absent, unsupported compression and corruption alike —
        // ZipReader deliberately does not distinguish them, and neither does
        // anything here: the entry is just not available.
        const QByteArray bytes = zip.read(name);
        if (bytes.isEmpty()) continue;

        if (isImageName(name)) {
            // Decode as the format the name claims, with autodetect off. A sniffing
            // loadFromData() would hand a `.bmp` holding SVG to Qt's SVG handler, which
            // resolves <image xlink:href="/abs/path"> from the local filesystem, letting
            // a skin read files back through MeloUiArchive::pixel(); sniffing also reaches
            // every installed handler (libraw, libheif, poppler on a stock KDE box).
            QBuffer buf;
            buf.setData(bytes);
            buf.open(QIODevice::ReadOnly);
            const qsizetype dot = name.lastIndexOf(QLatin1Char('.'));
            QImageReader reader(&buf, name.mid(dot + 1).toLower().toLatin1());
            reader.setAutoDetectImageFormat(false);
            reader.setAutoTransform(false);
            // Qt's own default is 128MB and applies to the DECODED size; a
            // skin bitmap that needs more than 64 is not a skin.
            reader.setAllocationLimit(64);

            // The declared size, checked before decoding, refuses a decode
            // bomb without paying for the inflate; the aggregate budget only
            // charges after a decode has run.
            const QSize dim = reader.size();
            if (dim.isValid()
                && qint64(dim.width()) * qint64(dim.height()) > kMaxImagePixels) continue;

            QImage img = reader.read();
            if (!img.isNull()) {
                decoded += img.sizeInBytes();
                a->images_.insert(key, img);
            } else {
                // A failed decode is not free. Charge for what it was allowed
                // to attempt, so an archive of nothing but failures still ends.
                decoded += qint64(bytes.size());
            }
        } else {
            const QString t = decodeText(bytes);
            decoded += qint64(t.size()) * qint64(sizeof(QChar));
            a->texts_.insert(key, t);
        }
    }

    return a;
}
