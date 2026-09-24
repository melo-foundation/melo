#include "SkinImageProvider.h"

#include "SkinArchive.h"

#include <QImage>
#include <QSize>
#include <QStringList>
#include <QUrl>

SkinImageProvider::SkinImageProvider(Resolver resolver)
    : QQuickImageProvider(QQuickImageProvider::Image),
      resolve_(std::move(resolver)) {}

QImage SkinImageProvider::requestImage(const QString& id, QSize* size,
                                       const QSize& requestedSize) {
    if (size) *size = QSize();

    const QStringList parts = id.split(QLatin1Char('/'));
    if (parts.size() != 3) return {};
    if (parts.at(0).isEmpty() || parts.at(1).isEmpty()
        || parts.at(2).isEmpty())
        return {};
    if (!resolve_) return {};

    // Decode the entry after the split, never before: %2F decodes to '/', so a
    // whole-id decode would let an entry name forge a component boundary.
    // Qt 6.10.3 hands requestImage a PrettyDecoded id, so only %25, %2F, %23 and
    // %3F are still encoded here.
    QString entry = parts.at(2);
    // Everything from the first '#' is the fragment MeloUiArchive::image adds so
    // QML's pixmap cache reloads, and Qt does not strip it. A literal '#' in a
    // name arrives as %23, so it survives this cut.
    const qsizetype hash = entry.indexOf(QLatin1Char('#'));
    if (hash >= 0) entry.truncate(hash);
    entry = QUrl::fromPercentEncoding(entry.toUtf8());
    if (entry.isEmpty()) return {};

    // Held for the rest of this call: the owner may swap the plugin's skin on
    // the GUI thread while this runs, and the archive being replaced must not
    // die under us.
    const std::shared_ptr<const SkinArchive> archive =
        resolve_(parts.at(0), parts.at(1));
    if (!archive) return {};

    const QImage img = archive->image(entry);
    if (img.isNull()) return {};

    // Contract: *size is the entry's own size, whatever we return below.
    if (size) *size = img.size();

    // requestedSize is QML's sourceSize, which may set one axis, both or
    // neither. Skins are pixel art — every scale here is nearest-neighbour, so
    // a doubled skin stays a doubled skin instead of a blurred one.
    const int w = requestedSize.width();
    const int h = requestedSize.height();
    if (w > 0 && h > 0)
        return img.scaled(w, h, Qt::IgnoreAspectRatio, Qt::FastTransformation);
    if (w > 0) return img.scaledToWidth(w, Qt::FastTransformation);
    if (h > 0) return img.scaledToHeight(h, Qt::FastTransformation);
    return img;
}
