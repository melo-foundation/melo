#pragma once

#include <QQuickImageProvider>
#include <QString>

#include <functional>
#include <memory>

class SkinArchive;

// Serves entries from plugin-supplied archives to plugin QML, one provider per
// plugin QML engine under kProviderId:
//
//     image://plugin-archive/<pluginId>/<settingsKey>/<entryName>
//
// Exactly three non-empty components, else a null image that never reaches
// the resolver. The entry component is percent-decoded after the split, so
// "sub%2Fmain.bmp" addresses a subfolder entry without forging a boundary.
// A trailing "#<n>" fragment is stripped; it makes the url unique after a skin
// swap so QML's pixmap cache reloads it.
//
// Constraints on the injected resolver:
//   * it runs on Qt's image loader thread (see SkinArchive.h), so it must be
//     thread-safe;
//   * it returns shared_ptr<const SkinArchive>, so the archive outlives the
//     call even if the owner swaps skins mid-request;
//   * both arguments are attacker-chosen and unnormalised: QUrl passes "..",
//     "." and backslashes intact ("image://plugin-archive/../skin/main.bmp"
//     gives pluginId ".."). A resolver that uses them as a path, a settings
//     group or anything else with structure must validate them first.
class SkinImageProvider : public QQuickImageProvider {
public:
    static constexpr char kProviderId[] = "plugin-archive";

    using Resolver = std::function<std::shared_ptr<const SkinArchive>(
        const QString& pluginId, const QString& settingsKey)>;

    explicit SkinImageProvider(Resolver resolver);

    // Null image on every failure: unparseable id, unknown plugin or key,
    // absent entry, undecodable entry. *size is set to the entry's real size
    // on success and left invalid otherwise.
    QImage requestImage(const QString& id, QSize* size,
                        const QSize& requestedSize) override;

private:
    const Resolver resolve_;
};
