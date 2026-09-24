#pragma once
#include <functional>
#include <QMap>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>
#include <QStringList>

// The theme FORMAT, apart from the store that holds themes: the role list,
// the version, and the parts a theme is made of. Pure Qt Core, so it can
// be linked into a test without the store's sidecar and settings behind it.
// See the top of ThemeStore.cpp for what the format is and why.
namespace ThemeFormat {
constexpr int kThemeVersion = 10;

QStringList surfaceRoles();
bool isSurfaceRole(const QString& key);
// panel, dialog, menu, toast, tooltip: absolute opacity, ignore opacityScale
bool isFloatingRole(const QString& key);
// one number per surface role, `content` for the ones contentOpacity used to multiply
QJsonObject opacityJson(double content);
// settings.opacityScale folded into the opacity map. A role's own opacity is
// absolute (see Theme.qml roleFrom) and a theme names every role, so the scale
// on its own reaches nothing; the non-floating surfaces are multiplied by it
// once, here.
QJsonObject foldOpacityScale(const QJsonObject& settings);

// The built-in bar layouts as documents (docs/bar-layout.md): rows,
// centre, strip, ministrip.
QJsonObject builtInLayout(const QString& id);
QStringList builtInLayoutIds();
// A theme is the parts it has: `palette` when it has colours; a settings
// part when any of the part's keys is in `settings`; and a part named in
// `parts` as a pointer to another theme, when that theme has it. The parts,
// in the strip's order, and a theme's settings with its pointers resolved
// through `lookup` (a theme by id, or an empty object).
QStringList partKinds();
QStringList partsOf(const QJsonObject& theme, const QMap<QString, QStringList>& keysOfPart,
                    const std::function<QJsonObject(const QString&)>& lookup);
QJsonObject resolvedSettings(const QJsonObject& theme, const QMap<QString, QStringList>& keysOfPart,
                             const std::function<QJsonObject(const QString&)>& lookup);
QJsonObject resolvedPalette(const QJsonObject& theme, const std::function<QJsonObject(const QString&)>& lookup);
// Taking parts of a theme: for the keys of the parts taken, the theme's
// value (merged with the defaults) is set and a key it lacks is cleared;
// for the keys of the parts kept, the current value is written down so the
// switch cannot replace it. Pure: settings and lists in, a patch and a
// clear list out. {"patch": {…}, "clear": [...]}
QJsonObject partsPatch(const QJsonObject& themeSettings, const QJsonObject& current,
                       const QStringList& takenKeys, const QStringList& keptKeys);

// An SVG file as a glyph entry. viewBox (or width/height) becomes `vb` and
// `ink`; every path, rect, circle, ellipse, polygon, polyline and line
// becomes path data; a translate — including a viewBox origin — is folded
// into the coordinates and any other transform is refused. Fill or stroke is
// whatever the first shape says. {"ok": true, "entry": {…}} or
// {"ok": false, "error": "…"}, the error being what the settings row shows.
QJsonObject importGlyphSvg(const QByteArray& svg);
}
