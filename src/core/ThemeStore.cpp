#include "ThemeStore.h"
#include "ThemeFormat.h"
#include "jsvalue.h"
using ThemeFormat::kThemeVersion;
using ThemeFormat::opacityJson;
#include <QColor>
#include "SettingsStore.h"
#include "paths.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QUrl>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPalette>
#include <QStyleHints>
#include <QEvent>
#include <QSaveFile>
#include <QFontDatabase>
#include <QSet>
#include <QStandardPaths>

// ---- theme format: roles ------------------------------------------------
//
// A palette entry is a role. Each surface is named for the one thing it
// paints (ThemeFormat::surfaceRoles()) and draws through Surface.qml, so
// blends and adaptive fills work on all of them; plus ink (text textSoft
// textDim textFaint textOverArt), lines (border borderStrong), accent (accent
// accentHover) and status (danger).
//
// A surface entry is a colour string, or an object when it is more than one:
//   "#151515"
//   { "colour": "#151515", "blend": "multiply" }
//   { "source": "adaptive", "amounts": { "hue": 0, "lum": -1, "sat": 0, "opacity": 1 } }
//
// Opacity lives in settings.opacity (one number per surface role), not the
// palette, so one palette serves the solid, glass and transparent built-ins.
// settings.opacityScale is folded into every role not floating over content
// (panel, dialog, menu, toast, tooltip keep theirs; ThemeFormat::
// foldOpacityScale). The transparency schemes are presets over opacityScale
// + glassBlur + fadeMode.
//
// A user file older than kThemeVersion is not loaded or imported.

static QJsonObject jpal(std::initializer_list<QPair<QString, QString>> kv) {
    QJsonObject o;
    for (const auto& p : kv) o.insert(p.first, p.second);
    return o;
}

static QJsonObject defaultSettingsJson() {
    return QJsonObject{
        {"hoverOpacity", 0.3}, {"miniHoverOpacity", 0.3},
        {"fadeMode", "off"}, {"miniFadeMode", "off"},
        {"visualizerBg", "transparent"},
        {"opacityScale", 1.0}, {"opacity", opacityJson(0.65)},
        {"glassBlur", "off"}, {"glassContrast", 1.0}, {"glassSaturation", 1.0},
        {"glassHoverDelay", 0}, {"hoverFadeMs", 180}, {"menuBlur", "off"},
        {"cornerStyle", "rounded"}, {"header", "stacked"},
        {"windowRadius", 4}, {"pageCorners", "none"}, {"windowBorderFit", "window"}, {"headerGroup", "separate"},
        {"borderSides", false}, {"borderLeft", 1}, {"borderTop", 1}, {"borderRight", 1}, {"borderBottom", 1},
        {"borderOuterWidth", 0}, {"borderInnerWidth", 0}, {"borderSoftOuter", 0}, {"borderSoftInner", 0}, {"borderSoftBands", 0}, {"borderSoftCurve", "smooth"}, {"borderTitle", false}, {"borderTitleRim", 0}, {"borderTitleFade", false}, {"windowShape", QJsonObject{}}, {"windowFrame", QJsonObject{}}, {"borderMaximized", false},
        {"windowRadiusBottom", -1},
        {"windowBorder", false}, {"windowBorderWidth", 1},
        {"windowOverBackground", false},
        {"font", "Red Hat Display"}, {"uiScale", 1}, {"fontScale", 1},
        {"spacingScale", 1}, {"controlScale", 1}, {"artScale", 1}, {"barScale", 1},
        {"fontWeight", 400}, {"titleFontSize", 12}, {"titleFontWeight", 0},
        {"viewTabs", "filled"}, {"chips", "pill"}, {"pageTabs", "underline"}, {"toggles", "segment"},
        {"tabGap", 2}, {"tabHeight", 22}, {"tabTrackPad", 4}, {"buttonGap", 2}, {"inputSelects", false}, {"buttonHeight", 22}, {"iconButtonSize", 26}, {"titleButtonSize", 0}, {"glyphSize", 14}, {"buttonPress", "none"},
        {"sliderTrackHeight", 4}, {"sliderKnobSize", 12}, {"sliderKnobShape", "round"}, {"sliderKnobAspect", 1}, {"volumeTrackHeight", 0}, {"volumeKnobSize", 0}, {"volumeKnobAspect", 0}, {"volumeKnobShape", ""}, {"volumeTrackShape", ""}, {"volumeKnobInset", -1}, {"sliderTrackShape", "round"}, {"scrollbars", "bar"}, {"scrollbarGrip", "none"}, {"scrollbarWidth", 0}, {"skeletonStyle", "shimmer"}, {"scrubberShape", "round"}, {"scrubberHover", "grow"}, {"scrubberKnobSize", 0}, {"scrubberKnobShape", "round"}, {"scrubberKnobAspect", 1},
        {"toggleWidth", 36}, {"toggleHeight", 20}, {"toggleKnobShape", "round"},
        {"titleButtons", "bare"}, {"toolButtons", "bare"}, {"transportButtons", "bare"},
        {"cardArtCorners", "auto"}, {"insets", QJsonObject{}}, {"glyphs", QJsonObject{}},
        // Every theme lever needs a default here (background is a part of
        // its own, the knob insets are in Controls), or picking a built-in
        // keeps whatever the last theme had. -1 on the insets is "auto", the
        // knob-size derivation Theme.qml does.
        {"background", QJsonObject{{"type", "none"}}},
        {"sliderKnobInset", -1}, {"scrubberKnobInset", -1},
        {"barMain", "rows"}, {"barNp", "centre"}, {"barMini", "rows"}, {"barTransition", "rise"},
        {"barSwapMs", 300},
        {"backMain", "surface"}, {"backNp", "none"}, {"backMini", "surface"},
        {"centreScrub", "auto"}, {"barResize", "ease"},
        {"floatInset", 10}, {"floatOffset", 0},
    };
}

static QJsonObject merged(const QJsonObject& base, const QJsonObject& over) {
    QJsonObject out = base;
    for (auto it = over.begin(); it != over.end(); ++it) out.insert(it.key(), it.value());
    return out;
}

// The transparency schemes (Solid, Glass, Transparent) are their own preset
// kind, so a theme switches between them in one click and the chip names the
// current one. A menu is opaque on Solid and 65% over a blur otherwise;
// `menuOpacity` is not a setting but is written into the opacity map
// (withMenuOpacity for built-ins, applyPreset for presets).
static QJsonObject schemeSolid() {
    return {{"opacityScale", 1.0}, {"glassBlur", "off"},
            {"fadeMode", "off"}, {"miniFadeMode", "off"},
            {"menuOpacity", 1.0}, {"menuBlur", "off"}};
}
static QJsonObject schemeGlass() {
    return {{"opacityScale", 0.35}, {"glassBlur", "focus"},
            {"fadeMode", "focus"}, {"miniFadeMode", "focus"},
            {"menuOpacity", 0.65}, {"menuBlur", "on"}};
}
static QJsonObject schemeTransparent() {
    return {{"opacityScale", 0.75}, {"glassBlur", "off"},
            {"fadeMode", "focus"}, {"miniFadeMode", "focus"},
            {"menuOpacity", 0.65}, {"menuBlur", "on"}};
}
// `menuOpacity` into the opacity map, where a menu reads it
static QJsonObject withMenuOpacity(QJsonObject settings) {
    if (!settings.contains(QStringLiteral("menuOpacity"))) return settings;
    QJsonObject op = settings.value(QStringLiteral("opacity")).toObject();
    op[QStringLiteral("menu")] = settings.value(QStringLiteral("menuOpacity")).toDouble();
    settings[QStringLiteral("opacity")] = op;
    settings.remove(QStringLiteral("menuOpacity"));
    return settings;
}

static QList<QJsonObject> builtInThemes() {
    const QJsonObject defs = defaultSettingsJson();
    // A built-in carries every part, melo's defaults under its own scheme,
    // so picking one is a whole reset.
    const QJsonObject glassy = merged(defs, schemeGlass());
    const QJsonObject solid = merged(defs, schemeSolid());
    const QJsonObject transparent = merged(defs, schemeTransparent());
    const QJsonObject lightDefs{{"fontWeight", 500}};

    const QJsonObject darkPalette = jpal({
        {"window", "#0f0f0f"}, {"chrome", "#151515"}, {"player", "#1a1a1a"},
        {"panel", "#151515"}, {"dialog", "#1a1a1a"}, {"menu", "#222222"},
        {"card", "#1a1a1a"}, {"button", "#222222"}, {"hover", "#333333"},
        {"selected", "#333333"}, {"toast", "#222222"}, {"scrollbar", "#333333"},
        {"tooltip", "#222222"}, {"text", "#e0e0e0"}, {"textSoft", "#aaaaaa"},
        {"textDim", "#888888"}, {"textFaint", "#666666"}, {"accent", "systemaccent:#cc3333"},
        {"accentHover", "systemaccent:#dd4444"}, {"border", "#2a2a2a"}, {"borderStrong", "#444444"}});
    const QJsonObject lightPalette = jpal({
        {"window", "#f5f5f5"}, {"chrome", "#ebebeb"}, {"player", "#e0e0e0"},
        {"panel", "#ebebeb"}, {"dialog", "#e0e0e0"}, {"menu", "#d6d6d6"},
        {"card", "#e0e0e0"}, {"button", "#d6d6d6"}, {"hover", "#c8c8c8"},
        {"selected", "#c8c8c8"}, {"toast", "#d6d6d6"}, {"scrollbar", "#c8c8c8"},
        {"tooltip", "#d6d6d6"}, {"text", "#1a1a1a"}, {"textSoft", "#666666"},
        {"textDim", "#555555"}, {"textFaint", "#888888"}, {"accent", "systemaccent:#cc3333"},
        {"accentHover", "systemaccent:#b82a2a"}, {"border", "#d0d0d0"}, {"borderStrong", "#b0b0b0"}});
    // The OS's colours: every value is a sentinel resolved in applyPalette()
    // from QGuiApplication::palette(), which the platform theme fills from the
    // desktop (kdeglobals on Plasma, the portal elsewhere), so this theme
    // follows light/dark without storing a colour. Derivations: systemRole().
    const QJsonObject systemPalette = jpal({
        {"window", "system:window"}, {"chrome", "system:base"}, {"player", "system:elevated"},
        {"panel", "system:base"}, {"dialog", "system:elevated"}, {"menu", "system:overlay"},
        {"card", "system:elevated"}, {"button", "system:overlay"}, {"hover", "system:hover"},
        {"selected", "system:selected"}, {"toast", "system:overlay"}, {"scrollbar", "system:hover"},
        {"tooltip", "system:overlay"}, {"text", "system:text"}, {"textSoft", "system:textSoft"},
        {"textDim", "system:textDim"}, {"textFaint", "system:textFaint"}, {"accent", "system:accent"},
        {"accentHover", "system:accentHover"}, {"border", "system:border"}, {"borderStrong", "system:borderStrong"}});
    const QJsonObject midnightPalette = jpal({
        {"window", "#0a1018"}, {"chrome", "#0e1520"}, {"player", "#131c28"},
        {"panel", "#0e1520"}, {"dialog", "#131c28"}, {"menu", "#1a2535"},
        {"card", "#131c28"}, {"button", "#1a2535"}, {"hover", "#283848"},
        {"selected", "#283848"}, {"toast", "#1a2535"}, {"scrollbar", "#283848"},
        {"tooltip", "#1a2535"}, {"text", "#d8e0ec"}, {"textSoft", "#99a5b4"},
        {"textDim", "#7a8899"}, {"textFaint", "#566070"}, {"accent", "#4a9eff"},
        {"accentHover", "#6ab0ff"}, {"border", "#1e2a3a"}, {"borderStrong", "#334466"}});
    const QJsonObject lightBluePalette = jpal({
        {"window", "#eef2f8"}, {"chrome", "#e4eaf2"}, {"player", "#d8e0ec"},
        {"panel", "#e4eaf2"}, {"dialog", "#d8e0ec"}, {"menu", "#ccd6e4"},
        {"card", "#d8e0ec"}, {"button", "#ccd6e4"}, {"hover", "#b8c8dc"},
        {"selected", "#b8c8dc"}, {"toast", "#ccd6e4"}, {"scrollbar", "#b8c8dc"},
        {"tooltip", "#ccd6e4"}, {"text", "#1a2030"}, {"textSoft", "#607080"},
        {"textDim", "#506070"}, {"textFaint", "#8090a0"}, {"accent", "#2870cc"},
        {"accentHover", "#1e5caa"}, {"border", "#c0cce0"}, {"borderStrong", "#a0b4cc"}});

    // the see-through built-ins keep their words legible with an outline on
    // the text ink: adaptive, so it is the words' own inverse on any palette
    auto outlined = [](const QJsonObject& palette) {
        QJsonObject pal = palette;
        const QJsonValue tv = pal["text"];
        QJsonObject text = tv.isObject() ? tv.toObject() : QJsonObject{{"colour", tv.toString()}};
        text["effect"] = QJsonObject{{"kind", "outline"}, {"size", 1.0}, {"soft", 0.0},
                                     {"dx", 0.0}, {"dy", 0.0}, {"opacity", 0.75},
                                     {"colour", QJsonObject{{"source", "adaptive"}}}};
        pal["text"] = text;
        return pal;
    };
    auto mk = [](const QString& id, const QString& name, const QJsonObject& palette,
                 const QJsonObject& settings) {
        return QJsonObject{{"version", kThemeVersion}, {"id", id}, {"name", name},
                           {"palette", palette},
                           // the scheme's master, folded into the map it has to
                           // reach — see ThemeFormat::foldOpacityScale
                           {"settings", ThemeFormat::foldOpacityScale(withMenuOpacity(settings))},
                           {"builtIn", true}};
    };

    return {
        // Follows the desktop. First in the list because people look for it
        // by name. Solid, like the desktop it follows, and the default a fresh
        // install starts on, so first run does not open see-through.
        mk("system", "System", systemPalette, solid),
        // dark glassy
        mk("dark-default", "Dark Glass", darkPalette, glassy),
        mk("midnight-blue", "Midnight Blue", midnightPalette,
           merged(glassy, {{"opacityScale", 0.5}})),
        mk("midnight-stars", "Midnight Stars", midnightPalette,
           merged(glassy, {
               {"opacityScale", 0.5}, {"opacity", opacityJson(0.85)},
               {"visualizerBg", "transparent"},
               {"background", QJsonObject{
                   {"type", "starfield"}, {"opacity", 0.35}, {"blur", 11},
                   {"scale", 1}, {"positionX", 0}, {"positionY", 0},
                   {"perModePosition", false}, {"behindWindow", false},
                   {"showInMini", true}, {"preserveInMini", true}, {"miniPositionY", 0.1},
                   {"options", QJsonObject{
                       {"colors", "#56b0c2,#4a9eff,#4daa5c"},
                       {"count", 140}, {"layers", 2},
                       {"speed", 1}, {"amplitude", 25}}}}}})),
        mk("rose", "Rose", jpal({
        {"window", "#150a10"}, {"chrome", "#1c0e15"}, {"player", "#22141c"},
        {"panel", "#1c0e15"}, {"dialog", "#22141c"}, {"menu", "#2e1a24"},
        {"card", "#22141c"}, {"button", "#2e1a24"}, {"hover", "#402838"},
        {"selected", "#402838"}, {"toast", "#2e1a24"}, {"scrollbar", "#402838"},
        {"tooltip", "#2e1a24"}, {"text", "#ece0e4"}, {"textSoft", "#b4909a"},
        {"textDim", "#99808a"}, {"textFaint", "#705060"}, {"accent", "#e06088"},
        {"accentHover", "#e880a0"}, {"border", "#301a24"}, {"borderStrong", "#503040"}}),
           merged(glassy, {{"opacityScale", 0.5}})),
        // dark solid
        mk("dark-solid", "Dark", darkPalette, solid),
        mk("oled-black", "OLED Black", jpal({
        {"window", "#000000"}, {"chrome", "#080808"}, {"player", "#0e0e0e"},
        {"panel", "#080808"}, {"dialog", "#0e0e0e"}, {"menu", "#161616"},
        {"card", "#0e0e0e"}, {"button", "#161616"}, {"hover", "#222222"},
        {"selected", "#222222"}, {"toast", "#161616"}, {"scrollbar", "#222222"},
        {"tooltip", "#161616"}, {"text", "#e0e0e0"}, {"textSoft", "#999999"},
        {"textDim", "#777777"}, {"textFaint", "#555555"}, {"accent", "#cc3333"},
        {"accentHover", "#dd4444"}, {"border", "#1a1a1a"}, {"borderStrong", "#333333"}}),
           solid),
        mk("charcoal", "Charcoal", jpal({
        {"window", "#1c1a18"}, {"chrome", "#222018"}, {"player", "#2a2820"},
        {"panel", "#222018"}, {"dialog", "#2a2820"}, {"menu", "#343028"},
        {"card", "#2a2820"}, {"button", "#343028"}, {"hover", "#443e34"},
        {"selected", "#443e34"}, {"toast", "#343028"}, {"scrollbar", "#443e34"},
        {"tooltip", "#343028"}, {"text", "#d8d0c8"}, {"textSoft", "#a89888"},
        {"textDim", "#908880"}, {"textFaint", "#686058"}, {"accent", "#e07838"},
        {"accentHover", "#e89050"}, {"border", "#302c24"}, {"borderStrong", "#504838"}}),
           solid),
        mk("forest", "Forest", jpal({
        {"window", "#0c120c"}, {"chrome", "#101810"}, {"player", "#162016"},
        {"panel", "#101810"}, {"dialog", "#162016"}, {"menu", "#1e2a1e"},
        {"card", "#162016"}, {"button", "#1e2a1e"}, {"hover", "#2c3c2c"},
        {"selected", "#2c3c2c"}, {"toast", "#1e2a1e"}, {"scrollbar", "#2c3c2c"},
        {"tooltip", "#1e2a1e"}, {"text", "#d8e4d8"}, {"textSoft", "#98b090"},
        {"textDim", "#80987a"}, {"textFaint", "#58705a"}, {"accent", "#4daa5c"},
        {"accentHover", "#60c070"}, {"border", "#1e2c1e"}, {"borderStrong", "#385038"}}),
           solid),
        // dark transparent
        mk("dark-transparent", "Dark Transparent", outlined(darkPalette), transparent),
        mk("midnight-transparent", "Blue Transparent", outlined(midnightPalette), transparent),
        // light
        mk("light", "Light", lightPalette, merged(solid, lightDefs)),
        mk("light-blue", "Light Blue", lightBluePalette, merged(solid, lightDefs)),
        mk("light-glass", "Light Glass", lightPalette,
           merged(merged(glassy, {{"opacityScale", 0.5}}), lightDefs)),
        mk("light-blue-glass", "Light Blue Glass", lightBluePalette,
           merged(merged(glassy, {{"opacityScale", 0.5}}), lightDefs)),
        mk("light-transparent", "Light Transparent", outlined(lightPalette),
           merged(transparent, lightDefs)),
    };
}

// live appearance keys (the slice a theme selection copies into settings)
static const char* kAppearanceKeys[] = {
    "hoverOpacity", "miniHoverOpacity", "fadeMode", "miniFadeMode",
    "visualizerBg", "opacityScale", "opacity",
    "glassBlur", "glassContrast", "glassSaturation", "glassHoverDelay", "hoverFadeMs",
    "menuBlur", "cornerStyle",
    "font", "uiScale", "fontScale", "fontWeight", "titleFontSize", "titleFontWeight",
    "spacingScale", "controlScale", "artScale", "barScale",
    "windowRadius", "windowBorder", "windowBorderWidth",
    "windowOverBackground", "header", "pageCorners", "windowBorderFit", "headerGroup",
    "borderSides", "borderLeft", "borderTop", "borderRight", "borderBottom", "borderOuterWidth", "borderInnerWidth", "borderSoftOuter", "borderSoftInner", "borderSoftBands", "borderSoftCurve", "borderTitle", "borderTitleRim", "borderTitleFade", "windowShape", "windowFrame", "borderMaximized", "windowRadiusBottom",
    "background",
    "viewTabs", "chips", "pageTabs", "toggles", "tabGap", "tabHeight", "tabTrackPad", "buttonGap", "inputSelects", "buttonHeight", "iconButtonSize", "titleButtonSize", "glyphSize", "buttonPress",
    "sliderTrackHeight", "sliderKnobSize", "sliderKnobShape", "sliderKnobAspect", "sliderTrackShape", "volumeTrackHeight", "volumeKnobSize", "volumeKnobAspect", "volumeKnobShape", "volumeTrackShape", "volumeKnobInset", "sliderKnobInset", "scrollbars", "scrollbarGrip", "scrollbarWidth", "skeletonStyle", "scrubberShape", "scrubberHover", "scrubberKnobSize", "scrubberKnobShape", "scrubberKnobAspect", "scrubberKnobInset", "toggleWidth", "toggleHeight", "toggleKnobShape",
    "titleButtons", "toolButtons", "transportButtons", "cardArtCorners", "insets",
    "glyphs",
    "barMain", "barNp", "barMini", "barTransition", "centreScrub", "barSwapMs",
    "backMain", "backNp", "backMini", "barResize", "floatInset", "floatOffset",
};

// The parts of a look. Every key in kAppearanceKeys belongs to exactly one
// part, and the palette is another, so applying one part leaves the others
// alone. scheme spans transparency and behaviour keys; it is applied and
// matched on its own without being a part.
static const char* kWindowKeys[] = {
    "cornerStyle", "windowRadius", "windowBorder", "windowBorderWidth",
    "windowOverBackground", "header", "pageCorners", "windowBorderFit", "headerGroup",
    "borderSides", "borderLeft", "borderTop", "borderRight", "borderBottom", "borderOuterWidth", "borderInnerWidth", "borderSoftOuter", "borderSoftInner", "borderSoftBands", "borderSoftCurve", "borderTitle", "borderTitleRim", "borderTitleFade", "windowShape", "windowFrame", "borderMaximized", "windowRadiusBottom",
};
static const char* kTypeKeys[] = {
    "font", "fontWeight", "titleFontSize", "titleFontWeight",
};
static const char* kSurfacesKeys[] = { "opacity" };
static const char* kTransparencyKeys[] = {
    "opacityScale", "glassBlur", "glassContrast", "glassSaturation", "menuBlur",
};
static const char* kBehaviourKeys[] = {
    "fadeMode", "miniFadeMode", "hoverOpacity", "miniHoverOpacity",
    "glassHoverDelay", "hoverFadeMs",
};
// How a strip draws its selected one: the header's view tabs, the chips
// on the home and library pages, the page tabs of the settings window and
// the queue panel. Each takes filled, pill or underline.
static const char* kControlsKeys[] = { "viewTabs", "chips", "pageTabs", "toggles", "tabGap", "tabHeight", "tabTrackPad", "buttonGap",
                                      "inputSelects", "buttonPress", "cardArtCorners", "buttonHeight", "iconButtonSize", "titleButtonSize", "glyphSize", "titleButtons", "toolButtons",
                                      "transportButtons", "sliderTrackHeight", "sliderKnobSize", "sliderKnobShape", "sliderKnobAspect", "volumeTrackHeight", "volumeKnobSize", "volumeKnobAspect", "volumeKnobShape", "volumeTrackShape", "volumeKnobInset",
                                      "sliderTrackShape", "sliderKnobInset", "scrollbars", "scrollbarGrip", "scrollbarWidth", "skeletonStyle", "scrubberShape", "scrubberHover", "scrubberKnobSize", "scrubberKnobShape", "scrubberKnobAspect", "scrubberKnobInset", "toggleWidth", "toggleHeight", "toggleKnobShape" };
// How far in a surface's content sits from its edge, per structure, four
// sides each: `insets` is an object keyed by structure, with the defaults in
// Theme. The card's are here too.
static const char* kInsetsKeys[] = { "insets" };
// What an icon is drawn from, per glyph name: an object in the table's own
// shape ({vb, ink, fill, sw, paths}), and a name it lacks draws the built-in
// in Theme.qml. Its own part because a set of icons travels on its own.
static const char* kGlyphsKeys[] = { "glyphs" };
// The player: the layout and the backing each place gets, how the two bars
// swap, where centre puts its scrub bar.
static const char* kPlayerKeys[] = { "barMain", "barNp", "barMini", "barTransition", "centreScrub",
                                     "backMain", "backNp", "backMini", "barResize", "barSwapMs",
                                     "floatInset", "floatOffset" };
static const char* kSchemeKeys[] = { "opacityScale", "glassBlur", "fadeMode", "miniFadeMode", "menuBlur" };
static const char* kBackgroundKeys[] = { "background", "visualizerBg" };
// How big everything is. Its own part because it is the one people change
// first and change often, and because "compact" is a choice about size, not
// about how the window is painted.
static const char* kSizeKeys[] = {
    "uiScale", "fontScale", "spacingScale", "controlScale", "artScale", "barScale",
};

static QStringList keysFor(const QString& kind) {
    QStringList out;
    auto take = [&out](auto& arr) { for (const char* k : arr) out << QLatin1String(k); };
    if (kind == QLatin1String("window")) take(kWindowKeys);
    else if (kind == QLatin1String("type")) take(kTypeKeys);
    else if (kind == QLatin1String("surfaces")) take(kSurfacesKeys);
    else if (kind == QLatin1String("transparency")) take(kTransparencyKeys);
    else if (kind == QLatin1String("behaviour")) take(kBehaviourKeys);
    else if (kind == QLatin1String("scheme")) take(kSchemeKeys);
    else if (kind == QLatin1String("background")) take(kBackgroundKeys);
    else if (kind == QLatin1String("size")) take(kSizeKeys);
    else if (kind == QLatin1String("controls")) take(kControlsKeys);
    else if (kind == QLatin1String("player")) take(kPlayerKeys);
    else if (kind == QLatin1String("insets")) take(kInsetsKeys);
    else if (kind == QLatin1String("glyphs")) take(kGlyphsKeys);
    return out;   // "palette" carries no settings keys; it is the palette object
}

using ThemeFormat::builtInLayout;
static const char* kBuiltInLayoutIds[] = { "rows", "centre", "strip", "ministrip" };
static const char* kPresetKinds[] = {
    "palette", "window", "type", "surfaces", "transparency", "behaviour",
    "scheme", "background", "size", "controls", "player", "layout", "insets", "glyphs",
};
static bool isPresetKind(const QString& kind) {
    for (const char* k : kPresetKinds) if (kind == QLatin1String(k)) return true;
    return false;
}

bool ThemeStore::isSurfaceRole(const QString& key) { return ThemeFormat::isSurfaceRole(key); }
bool ThemeStore::isFloatingRole(const QString& key) { return ThemeFormat::isFloatingRole(key); }
QStringList ThemeStore::surfaceRoles() { return ThemeFormat::surfaceRoles(); }

static QList<QJsonObject> builtInPresetsFrom(const QList<QJsonObject>& themes) {
    QList<QJsonObject> out;
    auto add = [&out](const QString& kind, const QString& id, const QString& name,
                      const QJsonObject& body) {
        for (const auto& p : out)
            if (p["kind"].toString() == kind && p["body"].toObject() == body) return;
        out.append(QJsonObject{{"id", id}, {"name", name}, {"kind", kind},
                               {"builtIn", true}, {"body", body}});
    };
    // One preset per background type, each a whole setup so the previous
    // background's tuning does not stay behind. All follow the starfield
    // preset's envelope (opacity, blur, scale, position, mini behaviour) plus
    // the options that mode reads.
    auto bgPreset = [](const char* type, double opacity, int blur,
                       const QJsonObject& options = {},
                       const QJsonObject& extra = {}) {
        QJsonObject cfg{{"type", QLatin1String(type)},
                        {"opacity", opacity}, {"blur", blur},
                        {"scale", 1}, {"positionX", 0}, {"positionY", 0},
                        {"perModePosition", false}, {"behindWindow", false},
                        {"showInMini", true}, {"preserveInMini", true},
                        {"miniPositionY", 0.1}};
        if (!options.isEmpty()) cfg["options"] = options;
        for (auto it = extra.begin(); it != extra.end(); ++it) cfg[it.key()] = it.value();
        return QJsonObject{{"background", cfg}};
    };
    const QString kCols = QStringLiteral("#cc3333,#4a9eff,#4daa5c");
    struct BgP { const char* id; const char* name; QJsonObject body; };
    const QList<BgP> kBackgrounds{
        {"none",      "None",      QJsonObject{{"background", QJsonObject{{"type", "none"}}}}},
        {"gradient",  "Gradient",  bgPreset("gradient", 1.0, 0, {},
                          {{"gradient", "linear-gradient(135deg, #1a2535, #0a1018)"}})},
        {"orbs",      "Orbs",      bgPreset("orbs", 0.5, 30,
                          {{"count", 8}, {"speed", 1}, {"minSize", 60},
                           {"maxSize", 200}, {"colors", kCols}})},
        {"waves",     "Waves",     bgPreset("waves", 0.45, 0,
                          {{"layers", 4}, {"amplitude", 60}, {"speed", 1},
                           {"position", 0.7}, {"colors", kCols}})},
        {"aurora",    "Aurora",    bgPreset("aurora", 0.5, 24,
                          {{"speed", 1}, {"bands", 4}, {"intensity", 0.6}})},
        {"mesh",      "Mesh",      bgPreset("mesh", 0.5, 24,
                          {{"speed", 1}, {"blobSize", 0.6}, {"colors", kCols}})},
        {"bokeh",     "Bokeh",     bgPreset("bokeh", 0.4, 6,
                          {{"speed", 1}, {"count", 15}, {"sizeRange", 60}, {"size", 20}})},
        {"particles", "Particles", bgPreset("particles", 0.5, 0,
                          {{"count", 80}, {"size", 2}, {"lines", true},
                           {"lineDistance", 120}, {"drift", 0.1}, {"colors", kCols}})},
        // the starfield is Midnight Stars'
        {"starfield", "Starfield", bgPreset("starfield", 0.35, 11,
                          {{"colors", "#56b0c2,#4a9eff,#4daa5c"}, {"count", 140},
                           {"layers", 2}, {"speed", 1}, {"amplitude", 25},
                           {"twinkle", true}, {"colored", false}})},
        {"vis-bars",  "Visualizer: Bars",  bgPreset("vis-bars", 0.5, 0,
                          {{"sensitivity", 1}, {"colors", kCols}})},
        {"vis-radial","Visualizer: Radial", bgPreset("vis-radial", 0.5, 0,
                          {{"sensitivity", 1}, {"rainbow", true}})},
        {"vis-oscilloscope", "Visualizer: Oscilloscope", bgPreset("vis-oscilloscope", 0.6, 0,
                          {{"sensitivity", 1}, {"color", "#4a9eff"}})},
        // no src: the picture is yours, the rest of the setup is not
        {"image",     "Image",     bgPreset("image", 1.0, 0, {}, {{"fit", "cover"}})},
    };
    for (const BgP& b : kBackgrounds)
        add(QStringLiteral("background"), QStringLiteral("bi-bg-") + QLatin1String(b.id),
            QLatin1String(b.name), b.body);

    // The three schemes, as presets of their own kind. A scheme is what a
    // transparency is: how much comes through, whether it is blurred, and
    // whether the window fades.
    struct Sc { const char* id; const char* name; QJsonObject body; };
    const Sc kSchemes[] = {
        {"solid",       "Solid",       schemeSolid()},
        {"glass",       "Glass",       schemeGlass()},
        {"transparent", "Transparent", schemeTransparent()},
    };
    for (const Sc& sc : kSchemes)
        add(QStringLiteral("scheme"), QStringLiteral("bi-scheme-") + QLatin1String(sc.id),
            QLatin1String(sc.name), sc.body);

    // The named sizes. A size sets all six kSizeKeys, so an old nudge cannot
    // ride along and the picker can name the size. fontScale, artScale and
    // barScale are 1: each multiplies uiScale (art(base) = base * uiScale *
    // artScale), so they already grow with the preset; nudging one afterwards
    // un-names the preset.
    struct Sz { const char* id; const char* name; double ui, gap, ctl; };
    static const Sz kSizes[] = {
        {"compact",     "Compact",     0.90, 0.75, 0.90},
        {"default",     "Default",     1.00, 1.00, 1.00},
        {"comfortable", "Comfortable", 1.10, 1.25, 1.10},
        {"large",       "Large",       1.30, 1.30, 1.25},
    };
    for (const Sz& z : kSizes)
        add(QStringLiteral("size"), QStringLiteral("bi-size-") + QLatin1String(z.id),
            QLatin1String(z.name),
            QJsonObject{{"uiScale", z.ui}, {"spacingScale", z.gap},
                        {"controlScale", z.ctl},
                        {"fontScale", 1.0}, {"artScale", 1.0}, {"barScale", 1.0}});

    // One small set for each other section, built from the keys the section
    // owns, so every fold has somewhere to start from.
    struct KV { const char* id; const char* name; QJsonObject body; };
    const KV kWindows[] = {
        {"soft",    "Soft",    QJsonObject{{"cornerStyle", "rounded"}, {"windowRadius", 4},
                                           {"windowBorder", false}, {"windowOverBackground", false}}},
        {"rounded", "Rounded", QJsonObject{{"cornerStyle", "rounded"}, {"windowRadius", 12},
                                           {"windowBorder", false}, {"windowOverBackground", false}}},
        {"squared", "Squared", QJsonObject{{"cornerStyle", "squared"}, {"windowRadius", 0},
                                           {"windowBorder", false}, {"windowOverBackground", false}}},
        {"framed",  "Framed",  QJsonObject{{"cornerStyle", "rounded"}, {"windowRadius", 8},
                                           {"windowBorder", true},
                                           {"windowBorderWidth", 1}, {"windowOverBackground", false}}},
    };
    for (const KV& w : kWindows)
        add(QStringLiteral("window"), QStringLiteral("bi-win-") + QLatin1String(w.id), QLatin1String(w.name), w.body);
    const KV kTypes[] = {
        {"light",   "Light",   QJsonObject{{"font", "Red Hat Display"}, {"fontWeight", 300}}},
        {"regular", "Regular", QJsonObject{{"font", "Red Hat Display"}, {"fontWeight", 400}}},
        {"medium",  "Medium",  QJsonObject{{"font", "Red Hat Display"}, {"fontWeight", 500}}},
        {"bold",    "Bold",    QJsonObject{{"font", "Red Hat Display"}, {"fontWeight", 700}}},
    };
    for (const KV& t : kTypes)
        add(QStringLiteral("type"), QStringLiteral("bi-type-") + QLatin1String(t.id), QLatin1String(t.name), t.body);
    auto opac = [](double window, double chrome, double player, double card, double field, double panel) {
        return QJsonObject{{"opacity", QJsonObject{
            {"window", window}, {"chrome", chrome}, {"player", player}, {"card", card}, {"button", field},
            {"hover", card}, {"selected", card}, {"scrollbar", card},
            {"panel", panel}, {"dialog", panel}, {"menu", panel}, {"toast", panel}, {"tooltip", panel}}}};
    };
    const KV kSurfaces[] = {
        {"solid",       "Solid",       opac(1, 1, 1, 1, 1, 1)},
        {"translucent", "Translucent", opac(0.55, 0.7, 0.7, 0.8, 0.8, 0.95)},
        {"sheer",       "Sheer",       opac(0.3, 0.4, 0.5, 0.6, 0.6, 0.9)},
        {"solid-panels","Glass, solid panels", opac(0.5, 0.6, 0.6, 0.7, 0.7, 1)},
    };
    for (const KV& sf : kSurfaces)
        add(QStringLiteral("surfaces"), QStringLiteral("bi-surf-") + QLatin1String(sf.id), QLatin1String(sf.name), sf.body);
    const KV kTransparency[] = {
        // the menu as the schemes have it: opaque when off, 65% over a blur otherwise
        {"off",     "Off",     QJsonObject{{"opacityScale", 1.0}, {"glassBlur", "off"}, {"glassContrast", 1.0},
                                           {"glassSaturation", 1.0}, {"menuBlur", "off"}, {"menuOpacity", 1.0}}},
        {"glass",   "Glass",   QJsonObject{{"opacityScale", 0.5}, {"glassBlur", "focus"}, {"glassContrast", 1.2},
                                           {"glassSaturation", 1.3}, {"menuBlur", "on"}, {"menuOpacity", 0.65}}},
        {"frosted", "Frosted", QJsonObject{{"opacityScale", 0.35}, {"glassBlur", "always"}, {"glassContrast", 1.3},
                                           {"glassSaturation", 1.5}, {"menuBlur", "on"}, {"menuOpacity", 0.65}}},
        {"clear",   "Clear",   QJsonObject{{"opacityScale", 0.75}, {"glassBlur", "off"}, {"glassContrast", 1.0},
                                           {"glassSaturation", 1.0}, {"menuBlur", "on"}, {"menuOpacity", 0.65}}},
    };
    for (const KV& tr : kTransparency)
        add(QStringLiteral("transparency"), QStringLiteral("bi-tr-") + QLatin1String(tr.id), QLatin1String(tr.name), tr.body);
    const KV kBehaviour[] = {
        {"steady",  "Steady",             QJsonObject{{"fadeMode", "off"}, {"miniFadeMode", "off"}, {"hoverOpacity", 0.3},
                                                      {"miniHoverOpacity", 0.3}, {"glassHoverDelay", 0}, {"hoverFadeMs", 180}}},
        {"focus",   "Fade on focus loss", QJsonObject{{"fadeMode", "focus"}, {"miniFadeMode", "focus"}, {"hoverOpacity", 0.35},
                                                      {"miniHoverOpacity", 0.35}, {"glassHoverDelay", 0}, {"hoverFadeMs", 180}}},
        {"leave",   "Fade on mouse leave", QJsonObject{{"fadeMode", "hover"}, {"miniFadeMode", "hover"}, {"hoverOpacity", 0.3},
                                                      {"miniHoverOpacity", 0.3}, {"glassHoverDelay", 250}, {"hoverFadeMs", 180}}},
    };
    for (const KV& b : kBehaviour)
        add(QStringLiteral("behaviour"), QStringLiteral("bi-beh-") + QLatin1String(b.id), QLatin1String(b.name), b.body);
    const KV kControls[] = {
        {"classic",   "Classic",    QJsonObject{{"viewTabs", "filled"}, {"chips", "pill"}, {"pageTabs", "underline"}, {"toggles", "segment"}}},
        {"filled",    "Filled",     QJsonObject{{"viewTabs", "filled"}, {"chips", "filled"}, {"pageTabs", "filled"}, {"toggles", "filled"}}},
        {"pills",     "Pills",      QJsonObject{{"viewTabs", "pill"}, {"chips", "pill"}, {"pageTabs", "pill"}, {"toggles", "pill"}}},
        {"underline", "Underlined", QJsonObject{{"viewTabs", "underline"}, {"chips", "underline"}, {"pageTabs", "underline"}, {"toggles", "underline"}}},
    };
    for (const KV& c : kControls)
        add(QStringLiteral("controls"), QStringLiteral("bi-ctl-") + QLatin1String(c.id), QLatin1String(c.name), c.body);
    const KV kPlayer[] = {
        {"classic",  "Classic",           QJsonObject{{"barMain", "rows"}, {"barNp", "centre"}, {"barMini", "rows"},
                                                      {"backMain", "surface"}, {"backNp", "none"}, {"backMini", "surface"},
                                                      {"barTransition", "rise"}, {"centreScrub", "auto"}}},
        {"centre",   "Centre everywhere", QJsonObject{{"barMain", "centre"}, {"barNp", "centre"}, {"barMini", "centre"},
                                                      {"backMain", "surface"}, {"backNp", "none"}, {"backMini", "surface"},
                                                      {"barTransition", "fade"}, {"centreScrub", "auto"}}},
        {"rows",     "Rows everywhere",   QJsonObject{{"barMain", "rows"}, {"barNp", "rows"}, {"barMini", "rows"},
                                                      {"backMain", "surface"}, {"backNp", "surface"}, {"backMini", "surface"},
                                                      {"barTransition", "none"}, {"centreScrub", "auto"}}},
        {"floating", "Floating",          QJsonObject{{"barMain", "rows"}, {"barNp", "centre"}, {"barMini", "rows"},
                                                      {"backMain", "floating"}, {"backNp", "floating"}, {"backMini", "floating"},
                                                      {"barTransition", "zoom"}, {"centreScrub", "under"}}},
        {"strip",    "Strip",             QJsonObject{{"barMain", "strip"}, {"barNp", "strip"}, {"barMini", "strip"},
                                                      {"backMain", "surface"}, {"backNp", "surface"}, {"backMini", "surface"},
                                                      {"barTransition", "fade"}, {"centreScrub", "auto"}}},
        {"ministrip", "Mini strip",       QJsonObject{{"barMain", "rows"}, {"barNp", "centre"}, {"barMini", "ministrip"},
                                                      {"backMain", "surface"}, {"backNp", "none"}, {"backMini", "surface"},
                                                      {"barTransition", "rise"}, {"centreScrub", "auto"}}},
    };
    for (const KV& p : kPlayer)
        add(QStringLiteral("player"), QStringLiteral("bi-ply-") + QLatin1String(p.id), QLatin1String(p.name), p.body);
    for (const char* lid : kBuiltInLayoutIds) {
        const QJsonObject d = builtInLayout(QLatin1String(lid));
        add(QStringLiteral("layout"), QLatin1String(lid), d["name"].toString(), d);
    }

    for (const QJsonObject& t : themes) {
        const QString id = t["id"].toString(), name = t["name"].toString();
        add(QStringLiteral("palette"), QStringLiteral("bi-pal-") + id, name,
            t["palette"].toObject());
        const QJsonObject ts = t["settings"].toObject();
        // Backgrounds are not derived from the themes: Midnight Stars'
        // starfield is the starfield preset.
        Q_UNUSED(ts);
    }
    return out;
}

// ---- store ----

ThemeStore::ThemeStore(SettingsStore* settings, QObject* parent)
    : QObject(parent), settings_(settings) {
    themesDir_ = meloConfigDir() + QStringLiteral("/themes");
    presetsDir_ = meloConfigDir() + QStringLiteral("/presets");
    defaults_ = defaultSettingsJson();
    builtIns_ = builtInThemes();
    loadUserThemes();
    loadUserPresets();
    activeId_ = QStringLiteral("system");
    // The System theme follows the desktop, so it has to be told when the
    // desktop moves. Qt raises ApplicationPaletteChange when the platform theme
    // re-reads the scheme, and colorSchemeChanged when only light/dark flips;
    // both reach the same re-resolve.
    if (qApp) qApp->installEventFilter(this);
    if (auto* hints = QGuiApplication::styleHints())
        connect(hints, &QStyleHints::colorSchemeChanged, this, [this] { applyPalette(); });
    applyPalette();
    rebuildSettings();

    // saved theme id + live appearance values arrive with the settings; any
    // later ui.* change (theme editor) re-derives the merged appearance
    connect(settings_, &SettingsStore::changed, this, [this] {
        const QString saved = settings_->uiGet("activeThemeId", activeId_).toString();
        if (!saved.isEmpty() && saved != activeId_ && !findTheme(saved).isEmpty()) {
            activeId_ = saved;
            applyPalette();
        }
        rebuildSettings();
        // a palette override arriving with the settings — from the sidecar
        // at start, or an edit — is drawn
        {
            static QVariantMap lastOver;
            const QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
            if (over != lastOver) { lastOver = over; applyPalette(); }
        }
        // And a slot's arrangement, the same way. What draws a bar reads the
        // override through a binding that re-runs when the layouts change; the
        // overrides arrive with the settings after that binding has been
        // evaluated, so themesChanged is what makes the bar read them.
        {
            static QVariantMap lastLayouts;
            const QVariantMap over = settings_->uiGet("layoutOverrides", QVariantMap{}).toMap();
            if (over != lastLayouts) { lastLayouts = over; emit themesChanged(); }
        }
    });
}

void ThemeStore::loadUserThemes() {
    userThemes_.clear();
    const QDir dir(themesDir_);
    for (const QString& name : dir.entryList({"*.json"}, QDir::Files, QDir::Name)) {
        QFile f(dir.filePath(name));
        if (!f.open(QIODevice::ReadOnly)) continue;
        const QJsonObject raw = QJsonDocument::fromJson(f.readAll()).object();
        if (raw["id"].toString().isEmpty()) continue;
        f.close();
        if (raw["version"].toInt() < kThemeVersion) {
            std::fprintf(stderr, "[theme] skipped %s: version %d, this build reads %d\n",
                         qPrintable(name), raw["version"].toInt(), kThemeVersion);
            continue;
        }
        QJsonObject t = raw;
        // the layouts a theme file carries become custom layouts, and its
        // slots point at them; the file is rewritten without them
        if (t.contains("layouts")) {
            const QJsonObject layouts = t["layouts"].toObject();
            QJsonObject ts = t["settings"].toObject();
            for (auto it = layouts.constBegin(); it != layouts.constEnd(); ++it) {
                const QJsonObject body = it.value().toObject();
                const QString nid = saveLayoutDoc(body.toVariantMap(), body["name"].toString());
                for (const char* slot : {"barMain", "barNp", "barMini"})
                    if (ts[QLatin1String(slot)].toString() == it.key()) ts[QLatin1String(slot)] = nid;
            }
            t["settings"] = ts;
            t.remove(QStringLiteral("layouts"));
        }
        if (t != raw) writeUserTheme(t);
        userThemes_.append(t);
    }
}

QJsonObject ThemeStore::findTheme(const QString& id) const {
    for (const auto& t : builtIns_) if (t["id"].toString() == id) return t;
    for (const auto& t : userThemes_) if (t["id"].toString() == id) return t;
    return {};
}

QString ThemeStore::activeName() const { return findTheme(activeId_)["name"].toString(); }
bool ThemeStore::activeBuiltIn() const { return findTheme(activeId_)["builtIn"].toBool(); }

QVariantList ThemeStore::themes() const {
    QVariantList out;
    auto add = [&out](const QJsonObject& t) {
        out.append(QVariantMap{{"id", t["id"].toString()}, {"name", t["name"].toString()},
                               {"builtIn", t["builtIn"].toBool()},
                               {"palette", t["palette"].toObject().toVariantMap()}});
    };
    for (const auto& t : builtIns_) add(t);
    for (const auto& t : userThemes_) add(t);
    return out;
}

// One OS colour, by role. Roles QPalette lacks are derived from the ones it
// has, lighter on a dark scheme and darker on a light one, so a surface is
// always a step away from its window.
static QColor systemRole(const QString& role) {
    const QPalette p = QGuiApplication::palette();
    const QColor window = p.color(QPalette::Window);
    const QColor text = p.color(QPalette::WindowText);
    const QColor accent = p.color(QPalette::Highlight);
    // The scheme as the palette itself reports it, not as a setting says: a
    // user with a dark scheme and a light theme file gets what they can see.
    const bool dark = window.lightness() < 128;
    // "Up" is away from the window's own lightness.
    auto step = [&](const QColor& from, int amount) {
        return dark ? from.lighter(100 + amount) : from.darker(100 + amount);
    };
    auto fade = [&](int percent) {
        QColor c = text;
        c.setAlpha(255);
        return QColor::fromHslF(c.hueF() < 0 ? 0 : c.hueF(), c.saturationF(),
                                dark ? qBound(0.0, c.lightnessF() * percent / 100.0, 1.0)
                                     : qBound(0.0, 1.0 - (1.0 - c.lightnessF()) * percent / 100.0,
                                              1.0));
    };

    if (role == QLatin1String("accent")) return accent;
    if (role == QLatin1String("accentHover")) return step(accent, 12);
    if (role == QLatin1String("text")) return text;
    if (role == QLatin1String("textSoft")) return fade(80);
    if (role == QLatin1String("textDim")) return fade(65);
    if (role == QLatin1String("textFaint")) return fade(45);
    if (role == QLatin1String("window")) return window;
    // Base is the colour lists and fields are drawn on — the header and the
    // panels here.
    if (role == QLatin1String("base")) return p.color(QPalette::Base);
    if (role == QLatin1String("elevated")) return step(window, 8);
    if (role == QLatin1String("overlay")) return step(window, 16);
    if (role == QLatin1String("hover")) return step(window, 28);
    // the current item is the one OS colour that MEANS "current"
    if (role == QLatin1String("selected")) {
        QColor c = accent; c.setAlpha(0x40); return c;
    }
    if (role == QLatin1String("border")) return p.color(QPalette::Mid);
    if (role == QLatin1String("borderStrong")) return p.color(QPalette::Midlight);
    return window;
}

bool ThemeStore::eventFilter(QObject* obj, QEvent* ev) {
    // One apply per change, after delivery: this app-wide filter sees the
    // event once per object, and applyPalette's themeChanged cascade sends more
    // back in, nested in the apply; applied inline, the GUI thread never leaves.
    if (ev->type() == QEvent::ApplicationPaletteChange && !paletteQueued_) {
        paletteQueued_ = true;
        QMetaObject::invokeMethod(this, [this] { paletteQueued_ = false; applyPalette(); },
                                  Qt::QueuedConnection);
    }
    return QObject::eventFilter(obj, ev);
}

void ThemeStore::applyPalette() {
    const QJsonObject theme = findTheme(activeId_);

    // The palette: the theme's, through a pointer if it names another's,
    // with the edits made since on top — those are ui.paletteOverrides, a
    // role to an entry, and no file holds them until Save as theme
    QJsonObject pal = ThemeFormat::resolvedPalette(theme, [this](const QString& i) { return findTheme(i); });
    QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
    // an override written when the role was still called `field`
    if (over.contains("field") && !over.contains("button")) { over["button"] = over.take("field"); }
    for (auto it = over.constBegin(); it != over.constEnd(); ++it) pal[it.key()] = QJsonValue::fromVariant(it.value());
    // resolve "systemaccent[:fallback]" to the OS accent (portal-fed QPalette)
    const QColor osAccent = QGuiApplication::palette().color(QPalette::Highlight);
    auto isSys = [](const QString& v) {
        return v == QLatin1String("systemaccent") || v.startsWith(QLatin1String("systemaccent:"));
    };
    const bool bothAccent = isSys(pal["accent"].toString()) && isSys(pal["accentHover"].toString());
    auto resolveColour = [&](const QString& v) -> QString {
        if (isSys(v)) return osAccent.name();
        // "system:<role>" — the System theme's whole palette. See systemRole().
        if (v.startsWith(QLatin1String("system:"))) return systemRole(v.mid(7)).name(QColor::HexArgb);
        return v;
    };
    QVariantMap resolved;
    for (auto it = pal.begin(); it != pal.end(); ++it) {
        const QJsonValue entry = it.value();
        // A surface entry may be an object: its `colour` resolves like a plain
        // entry and the rest (source, blend, amounts) rides along untouched.
        if (entry.isObject()) {
            QVariantMap o = entry.toObject().toVariantMap();
            // Only what is there: a stack of layers has no colour of its own,
            // and a default would give it a white one that every reader taking
            // a single value paints.
            if (o.contains("colour")) o["colour"] = resolveColour(o.value("colour").toString());
            resolved.insert(it.key(), o);
            continue;
        }
        resolved.insert(it.key(), resolveColour(entry.toString()));
    }
    // Alpha goes first: Qt reads a nine-character colour as #AARRGGBB, so
    // "dd" appended to "#cc3333" would read as alpha cc and blue dd.
    // name(HexArgb) puts the alpha where Qt looks for it.
    if (bothAccent) {
        QColor hover = osAccent;
        hover.setAlpha(0xdd);
        resolved["accentHover"] = hover.name(QColor::HexArgb);
    }
    // An apply that changes nothing emits nothing. themeChanged re-evaluates
    // every binding that reads the theme, and that cascade delivers the next
    // palette change, so the two would feed each other. The system sends this
    // event for reasons that leave our colours as they were, and those end here.
    if (resolved == resolvedPalette_) return;
    resolvedPalette_ = resolved;
    emit paletteChanged();
    emit themeChanged();
}

// live appearance: defaults <- active theme's settings <- ui.* overrides
void ThemeStore::rebuildSettings() {
    const QJsonObject themeSettings = themeSettingsOf(findTheme(activeId_));
    if (qEnvironmentVariableIsSet("MELO_BG_DEBUG"))
        qDebug() << "[bg-debug] rebuildSettings active" << activeId_
                 << "themeHasBg" << themeSettings.contains("background")
                 << "uiHasBg" << settings_->uiHas("background")
                 << "userThemes" << userThemes_.size() << "dir" << themesDir_;
    QVariantMap out;
    for (const char* k : kAppearanceKeys) {
        const QString key = QLatin1String(k);
        if (settings_->uiHas(key)) out[key] = settings_->uiGet(key);
        else if (themeSettings.contains(key)) out[key] = themeSettings[key].toVariant();
        else if (defaults_.contains(key)) out[key] = defaults_[key].toVariant();
    }
    if (qEnvironmentVariableIsSet("MELO_THEME_DEBUG")) {
        const QVariantMap op = out.value(QStringLiteral("opacity")).toMap();
        std::fprintf(stderr, "[theme] %s  opacityScale=%.2f  glassBlur=%s  window=%.2f "
                             "chrome=%.2f card=%.2f  (opacity map: %d entries)\n",
                     qPrintable(activeId_),
                     out.value(QStringLiteral("opacityScale"), -1).toDouble(),
                     qPrintable(out.value(QStringLiteral("glassBlur")).toString()),
                     op.value(QStringLiteral("window"), -1).toDouble(),
                     op.value(QStringLiteral("chrome"), -1).toDouble(),
                     op.value(QStringLiteral("card"), -1).toDouble(), int(op.size()));
    }
    // CUSTOM: an override on a part the theme has that differs from it, or a
    // colour edited since. A part the theme lacks does not count.
    bool dirty = !settings_->uiGet("paletteOverrides", QVariantMap{}).toMap().isEmpty();
    if (!dirty) {
        const QStringList has = partsOfTheme(activeId_);
        for (const QString& part : has) {
            if (part == QLatin1String("palette")) continue;
            for (const QString& k : keysFor(part)) {
                if (!settings_->uiHas(k)) continue;
                const QJsonValue want = themeSettings.contains(k) ? themeSettings[k] : defaults_[k];
                if (QJsonValue::fromVariant(settings_->uiGet(k, {})) != want) { dirty = true; break; }
            }
            if (dirty) break;
        }
        // an arranged bar is an edit to the player, like any of its keys
        if (!dirty && has.contains(QStringLiteral("player")) && anyLayoutOverride()) dirty = true;
    }
    if (out != mergedSettings_ || dirty != dirty_) {
        const bool settingsMoved = out != mergedSettings_;
        mergedSettings_ = out;
        dirty_ = dirty;
        if (settingsMoved) emit settingsChanged();
        emit themeChanged();
    }
    if (qEnvironmentVariableIsSet("MELO_THEME_DEBUG"))
        std::fprintf(stderr, "[theme] rebuild %s accent=%s\n", qPrintable(activeId_),
                     qPrintable(resolvedPalette_.value(QStringLiteral("accent")).toString()));
}

// the parts a theme is made of, in the order the strip shows them
static const char* kThemeParts[] = {
    "palette", "window", "type", "surfaces", "transparency", "behaviour", "size", "background", "controls", "glyphs", "player", "insets",
};
QStringList ThemeStore::themeParts() const {
    QStringList out;
    for (const char* p : kThemeParts) out << QLatin1String(p);
    return out;
}
static QMap<QString, QStringList> keysOfParts() {
    QMap<QString, QStringList> m;
    for (const char* p : kThemeParts) m[QLatin1String(p)] = keysFor(QLatin1String(p));
    return m;
}
QStringList ThemeStore::partsOfTheme(const QString& id) const {
    const QJsonObject t = findTheme(id);
    return ThemeFormat::partsOf(t, keysOfParts(), [this](const QString& i) { return findTheme(i); });
}
// the theme's settings with its pointers followed
QJsonObject ThemeStore::themeSettingsOf(const QJsonObject& t) const {
    return ThemeFormat::resolvedSettings(t, keysOfParts(), [this](const QString& i) { return findTheme(i); });
}

void ThemeStore::setActive(const QString& id) { applyThemeParts(id, themeParts()); }

// the theme's palette, edits aside
static QJsonObject themePaletteOf(const QJsonObject& theme, const std::function<QJsonObject(const QString&)>& lookup) {
    return ThemeFormat::resolvedPalette(theme, lookup);
}
bool ThemeStore::rolesDirty(const QStringList& roles, bool others) const {
    const QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
    if (over.isEmpty()) return false;
    const QJsonObject pal = themePaletteOf(findTheme(activeId_), [this](const QString& i) { return findTheme(i); });
    for (auto it = over.constBegin(); it != over.constEnd(); ++it) {
        if (roles.contains(it.key()) == others) continue;
        if (QJsonValue::fromVariant(it.value()) != pal.value(it.key())) return true;
    }
    return false;
}
void ThemeStore::discardRoles(const QStringList& roles, bool others) {
    QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
    for (auto it = over.begin(); it != over.end();) {
        if (roles.contains(it.key()) != others) it = over.erase(it); else ++it;
    }
    settings_->uiSet("paletteOverrides", over);   // applyPalette runs via changed()
    applyPalette();
}
QVariant ThemeStore::themeEntry(const QString& role) const {
    const QJsonObject pal = themePaletteOf(findTheme(activeId_), [this](const QString& i) { return findTheme(i); });
    return pal.contains(role) ? pal.value(role).toVariant() : QVariant();
}
bool ThemeStore::partDirty(const QString& part) const {
    if (part == QLatin1String("palette")) return rolesDirty({}, true);
    if (part == QLatin1String("player") && anyLayoutOverride()) return true;
    const QJsonObject ts = themeSettingsOf(findTheme(activeId_));
    for (const QString& k : keysFor(part)) {
        if (!settings_->uiHas(k)) continue;
        const QJsonValue want = ts.contains(k) ? ts[k] : defaults_[k];
        if (QJsonValue::fromVariant(settings_->uiGet(k, {})) != want) return true;
    }
    return false;
}
void ThemeStore::discardPart(const QString& part) {
    if (part == QLatin1String("palette")) { discardRoles({}, true); return; }
    settings_->uiApply({}, keysFor(part));   // rebuildSettings runs via changed()
}

void ThemeStore::applyThemeParts(const QString& id, const QStringList& parts) {
    const QJsonObject theme = findTheme(id);
    if (theme.isEmpty()) return;
    const bool takePalette = parts.contains(QStringLiteral("palette"));
    if (takePalette && id == activeId_ && parts.size() == themeParts().size()) return;
    // a part the theme does not have is kept whatever was asked
    const QStringList has = partsOfTheme(id);
    QStringList taken, kept;
    for (const char* p : kThemeParts) {
        const QString part = QLatin1String(p);
        if (part == QLatin1String("palette")) continue;
        (parts.contains(part) && has.contains(part) ? taken : kept) << keysFor(part);
    }
    // Adopt the parts taken in one RPC patch: keys the theme (or defaults)
    // defines are set, keys it lacks lose their ui override, so a background
    // cannot survive a switch to a theme without one. Kept parts have their
    // current values written first so the switch cannot replace them.
    const QJsonObject ts = merged(defaults_, themeSettingsOf(theme));
    const QJsonObject pp = ThemeFormat::partsPatch(ts, QJsonObject::fromVariantMap(mergedSettings_),
                                                   taken, takePalette ? kept : QStringList{});
    QVariantMap patch = pp["patch"].toObject().toVariantMap();
    QStringList clear;
    for (const auto& c : pp["clear"].toArray()) clear << c.toString();
    if (takePalette && has.contains(QStringLiteral("palette"))) {
        activeId_ = id;
        patch["activeThemeId"] = id;
        patch["paletteOverrides"] = QVariantMap{};   // the new theme's colours, as they are
        applyPalette();
    }
    // the swatches edited at the level of the theme go the same way the
    // palette overrides do: back to what the theme's file says
    if (takePalette) clear << QStringLiteral("themeSwatches");
    settings_->uiApply(patch, clear);   // triggers rebuildSettings via changed()
    if (takePalette) emit themeSwatchesChanged();
    // A theme's player replaces what each slot draws, as a layout preset's
    // does (applyPreset): an unsaved arrangement wins over the id a slot
    // names, so it is cleared or the theme's bar would never show.
    for (const QLatin1String slot : { QLatin1String("barMain"), QLatin1String("barNp"), QLatin1String("barMini") })
        if ((patch.contains(slot) || clear.contains(slot)) && hasLayoutOverride(slot)) clearLayoutOverride(slot);
}

// Discard: back to the theme as its file has it — every part it has adopted
// wholesale, the palette overrides dropped
void ThemeStore::discard() {
    const QStringList parts = themeParts();
    const QString id = activeId_;
    activeId_.clear();   // so the apply is not skipped as a no-op
    applyThemeParts(id, parts);
}

// The built-in a part is identical to, if any. For a settings part the
// current merged values against the built-in's, with the defaults filling
// what it does not say; for the palette, the active theme's palette when it
// is or points at a built-in's and nothing has been edited over it.
QString ThemeStore::builtInMatching(const QString& part) const {
    if (part == QLatin1String("palette")) {
        if (!settings_->uiGet("paletteOverrides", QVariantMap{}).toMap().isEmpty()) return {};
        const QJsonObject active = findTheme(activeId_);
        const QString from = active["parts"].toObject()["palette"].toString();
        const QString id = active["builtIn"].toBool() ? activeId_ : from;
        return !id.isEmpty() && findTheme(id)["builtIn"].toBool() ? id : QString{};
    }
    const QStringList keys = keysFor(part);
    for (const QJsonObject& b : builtIns_) {
        const QJsonObject bs = themeSettingsOf(b);
        bool has = false, same = true;
        for (const QString& k : keys) {
            if (bs.contains(k)) has = true;
            const QJsonValue want = bs.contains(k) ? bs[k] : defaults_[k];
            if (QJsonValue::fromVariant(mergedSettings_.value(k)) != want) { same = false; break; }
        }
        if (has && same) return b["id"].toString();
    }
    return {};
}

// The shelf swatches this palette's entries name, via `from` at the entry's
// top level (a stack keeps it there too, beside its layers).
static QJsonArray swatchesFor(const QJsonObject& palette, const QVariantList& shelf) {
    QSet<QString> wanted;
    for (auto it = palette.constBegin(); it != palette.constEnd(); ++it) {
        if (!it.value().isObject()) continue;
        const QString from = it.value().toObject().value("from").toString();
        if (!from.isEmpty()) wanted.insert(from);
    }
    QJsonArray out;
    if (wanted.isEmpty()) return out;
    for (const QVariant& v : shelf) {
        const QVariantMap m = v.toMap();
        if (wanted.contains(m.value("id").toString()))
            out.append(QJsonObject::fromVariantMap(m));
    }
    return out;
}

// Union by id, the first list winning. What a theme is written with: the swatches
// set at the level of the theme, then the stamped ones it does not name yet.
static QJsonArray unionById(QJsonArray a, const QJsonArray& b) {
    QSet<QString> seen;
    for (const QJsonValue& v : a) seen.insert(v.toObject().value("id").toString());
    for (const QJsonValue& v : b) {
        const QJsonObject o = v.toObject();
        const QString id = o.value("id").toString();
        if (id.isEmpty() || seen.contains(id)) continue;
        seen.insert(id);
        a.append(o);
    }
    return a;
}

QVariantList ThemeStore::themeSwatches(const QString& id) const {
    if ((id.isEmpty() || id == activeId_) && settings_->uiHas(QStringLiteral("themeSwatches")))
        return settings_->uiGet(QStringLiteral("themeSwatches")).toList();
    const QJsonObject t = findTheme(id.isEmpty() ? activeId_ : id);
    return t.value("swatches").toArray().toVariantList();
}

void ThemeStore::setThemeSwatches(const QVariantList& list) {
    settings_->uiSet(QStringLiteral("themeSwatches"), list);
    emit themeSwatchesChanged();
}

// Save as theme, part by part: "own" writes the current values (or a pointer
// to a built-in whose part is identical), "off" leaves it out. The new theme
// becomes active and nothing is Custom any more.
QString ThemeStore::saveThemeAs(const QString& name, const QVariantMap& choices) {
    if (choices.value(QStringLiteral("player"), QStringLiteral("own")).toString() == QLatin1String("own"))
        foldLayoutOverrides(QString(), name.isEmpty() ? activeName() + QStringLiteral(" Copy") : name);
    const QString id = QStringLiteral("custom-%1").arg(QDateTime::currentMSecsSinceEpoch());
    QJsonObject t{{"version", kThemeVersion}, {"id", id},
                  {"name", name.isEmpty() ? activeName() + QStringLiteral(" Copy") : name}, {"builtIn", false}};
    QJsonObject palette, settings, parts;
    for (const char* p : kThemeParts) {
        const QString part = QLatin1String(p);
        const QString choice = choices.value(part, QStringLiteral("own")).toString();
        if (choice == QLatin1String("off")) continue;
        // identical to a default theme's part: a pointer, so the file stays
        // small and an import puts nothing on the list that is already there
        const QString same = builtInMatching(part);
        if (!same.isEmpty()) { parts[part] = same; continue; }
        if (part == QLatin1String("palette")) { palette = QJsonObject::fromVariantMap(resolvedPalette_); continue; }
        for (const QString& k : keysFor(part))
            if (mergedSettings_.contains(k)) settings[k] = QJsonValue::fromVariant(mergedSettings_[k]);
    }
    t["palette"] = palette;
    t["settings"] = settings;
    if (!parts.isEmpty()) t["parts"] = parts;
    {
        const QJsonArray sw = unionById(
            QJsonArray::fromVariantList(themeSwatches()),
            swatchesFor(palette, settings_->uiGet("swatches", QVariantList{}).toList()));
        if (!sw.isEmpty()) t["swatches"] = sw;
    }
    userThemes_.append(t);
    writeUserTheme(t);
    emit themesChanged();
    activeId_.clear();
    applyThemeParts(id, themeParts());
    return id;
}

void ThemeStore::setThemeSetting(const QString& key, const QVariant& value) {
    settings_->uiSet(key, value);   // rebuildSettings runs via changed()
}

static QString portalPath(const QString& p) {
    return p.startsWith(QStringLiteral("file://")) ? QUrl(p).toLocalFile() : p;
}

// Save over the active theme: every part it has, as it is now — a part
// that pointed at another theme's becomes its own, since what is on screen
// is what was asked for. A part it lacks stays where it was, which is the
// profile: it is not the theme's, and `dirty` never counted it either.
bool ThemeStore::saveActive() {
    const QString id = activeId_;
    QJsonObject t = findTheme(id);
    if (t.isEmpty() || t["builtIn"].toBool()) return false;
    const QStringList has = partsOfTheme(id);
    if (has.contains(QStringLiteral("player"))) foldLayoutOverrides(id, t["name"].toString());
    QJsonObject settings = t["settings"].toObject(), parts = t["parts"].toObject();
    for (const QString& part : has) {
        parts.remove(part);
        if (part == QLatin1String("palette")) { t["palette"] = QJsonObject::fromVariantMap(resolvedPalette_); continue; }
        for (const QString& k : keysFor(part))
            if (mergedSettings_.contains(k)) settings[k] = QJsonValue::fromVariant(mergedSettings_[k]);
    }
    t["settings"] = settings;
    if (parts.isEmpty()) t.remove("parts"); else t["parts"] = parts;
    const QJsonArray sw = unionById(QJsonArray::fromVariantList(themeSwatches(id)),
                                    swatchesFor(t["palette"].toObject(),
                                                settings_->uiGet("swatches", QVariantList{}).toList()));
    if (sw.isEmpty()) t.remove("swatches"); else t["swatches"] = sw;
    for (QJsonObject& u : userThemes_) if (u["id"].toString() == id) u = t;
    writeUserTheme(t);
    emit themesChanged();
    // the file says what the screen does now, so the edits are no longer
    // edits: re-apply it and the overrides go, as Discard's do
    activeId_.clear();
    applyThemeParts(id, themeParts());
    return true;
}

bool ThemeStore::exportTheme(const QString& id, const QString& path) {
    QJsonObject t = findTheme(id.isEmpty() ? activeId_ : id);
    if (t.isEmpty()) return false;
    // The theme travels with its swatches, for the same reason it travels with
    // its bar: on another machine the shelf they came from is not there.
    {
        const QJsonArray sw = unionById(
            QJsonArray::fromVariantList(themeSwatches(id)),
            swatchesFor(t["palette"].toObject(),
                        settings_->uiGet("swatches", QVariantList{}).toList()));
        if (!sw.isEmpty()) t["swatches"] = sw;
    }
    // The theme travels with its bar: a custom layout a slot names goes in
    // the file under "layouts", so the bar it draws arrives with it
    {
        const QJsonObject ts = t["settings"].toObject();
        QJsonObject layouts;
        for (const char* slot : {"barMain", "barNp", "barMini"}) {
            const QString lid = ts[QLatin1String(slot)].toString();
            if (lid.isEmpty() || isBuiltInLayout(lid) || layouts.contains(lid)) continue;
            const QJsonObject p = findPreset(QStringLiteral("layout"), lid);
            if (!p.isEmpty()) layouts[lid] = p["body"];
        }
        if (!layouts.isEmpty()) t["layouts"] = layouts;
    }
    QString p = portalPath(path);
    if (!p.endsWith(QStringLiteral(".json"), Qt::CaseInsensitive))
        p += QStringLiteral(".json");
    QFile f(p);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write(QJsonDocument(t).toJson(QJsonDocument::Indented));
    return true;
}

// An SVG file as a glyph entry, for the row that is about to write it into
// `glyphs`. The parsing is in ThemeFormat so a test can hand it a string.
QVariantMap ThemeStore::importGlyph(const QString& path) const {
    QFile f(portalPath(path));
    if (!f.open(QIODevice::ReadOnly))
        return QJsonObject{{"ok", false}, {"error", QStringLiteral("cannot read the file")}}.toVariantMap();
    return ThemeFormat::importGlyphSvg(f.readAll()).toVariantMap();
}

QString ThemeStore::importTheme(const QString& path) {
    lastError_.clear();
    emit lastErrorChanged();
    QFile f(portalPath(path));
    if (!f.open(QIODevice::ReadOnly)) return {};
    QJsonObject t = QJsonDocument::fromJson(f.readAll()).object();
    // a theme without a palette is not one; settings may legitimately be empty
    if (t.isEmpty() || !t.contains("palette")) return {};
    if (t["version"].toInt() < kThemeVersion) {
        lastError_ = QStringLiteral("theme version %1; this build reads %2")
                         .arg(t["version"].toInt()).arg(kThemeVersion);
        emit lastErrorChanged();
        return {};
    }
    // the layouts it carries become custom layouts here, under fresh ids,
    // and its slots are pointed at them
    if (t.contains("layouts")) {
        const QJsonObject layouts = t["layouts"].toObject();
        QJsonObject ts = t["settings"].toObject();
        QHash<QString, QString> fresh;
        for (auto it = layouts.constBegin(); it != layouts.constEnd(); ++it) {
            const QJsonObject body = it.value().toObject();
            fresh[it.key()] = saveLayoutDoc(body.toVariantMap(), body["name"].toString());
        }
        for (const char* slot : {"barMain", "barNp", "barMini"}) {
            const QString lid = ts[QLatin1String(slot)].toString();
            if (fresh.contains(lid)) ts[QLatin1String(slot)] = fresh[lid];
        }
        t["settings"] = ts;
        t.remove(QStringLiteral("layouts"));
    }

    // Every colour has to be one: Qt.color("nope") throws in QML and the
    // property reads back #000000, so one typo'd key turns the whole UI black,
    // Settings included. Past this point it looks like a chosen colour.
    {
        const QJsonObject pal = t["palette"].toObject();
        QStringList bad;
        for (auto it = pal.constBegin(); it != pal.constEnd(); ++it) {
            // a surface object carries its colour in `colour`
            const QString v = it.value().isObject()
                ? it.value().toObject().value("colour").toString(QStringLiteral("#ffffff"))
                : it.value().toString();
            if (!it.value().isString() && !it.value().isObject()) { bad << it.key(); continue; }
            // QColor::isValidColorName covers names, #rgb/#rrggbb/#aarrggbb,
            // and rejects everything else without throwing.
            if (!QColor::isValidColorName(v)) bad << (it.key() + " = " + v);
        }
        if (!bad.isEmpty()) {
            lastError_ = QStringLiteral("not a colour: %1").arg(bad.join(QStringLiteral(", ")));
            emit lastErrorChanged();
            std::fprintf(stderr, "[theme] refusing %s — %s\n",
                         qPrintable(path), qPrintable(lastError_));
            return {};
        }
    }
    // never adopt the file's id: it would collide with, and shadow, a theme
    // already here
    const QString id = QStringLiteral("custom-%1").arg(QDateTime::currentMSecsSinceEpoch());
    t["id"] = id;
    t["builtIn"] = false;
    if (t["name"].toString().isEmpty()) t["name"] = QStringLiteral("Imported theme");
    userThemes_.append(t);
    writeUserTheme(t);

    // A theme that brings a background brings a composition someone made, and
    // it would otherwise only be reachable by wearing the whole theme. Keep it
    // as a background preset under the theme's own name, so it can be put on
    // any palette and any style.
    const QJsonObject bg = t["settings"].toObject()["background"].toObject();
    if (!bg.isEmpty() && bg["type"].toString() != QLatin1String("none")) {
        const QJsonObject body{{"background", bg}};
        bool have = false;
        for (const auto& p : userPresets_)
            if (p["kind"].toString() == QLatin1String("background")
                && p["body"].toObject() == body) { have = true; break; }
        if (!have) {
            const QJsonObject preset{
                {"id", QStringLiteral("background-%1").arg(QDateTime::currentMSecsSinceEpoch())},
                {"name", t["name"].toString()},
                {"kind", QStringLiteral("background")}, {"builtIn", false}, {"body", body}};
            userPresets_.append(preset);
            writeUserPreset(preset);
        }
    }

    emit themesChanged();
    return id;
}

void ThemeStore::deleteTheme(const QString& id) {
    for (int i = 0; i < userThemes_.size(); ++i) {
        if (userThemes_[i]["id"].toString() == id) {
            userThemes_.removeAt(i);
            QFile::remove(themesDir_ + "/" + id + ".json");
            emit themesChanged();
            if (activeId_ == id) setActive(QStringLiteral("system"));
            return;
        }
    }
}

// An edit to a colour is an override, not a write to a file: the theme
// stays what it is and the look is Custom until Save as theme.
void ThemeStore::setPaletteColor(const QString& key, const QVariant& value) {
    QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
    // unwrapJs FIRST: the picker hands over a JS object for anything that is
    // not a plain colour, and fromVariant turns an unwrapped one into null.
    over[key] = QJsonValue::fromVariant(unwrapJs(value)).toVariant();
    settings_->uiSet("paletteOverrides", over);   // applyPalette runs via changed()
    applyPalette();
    if (qEnvironmentVariableIsSet("MELO_THEME_DEBUG"))
        std::fprintf(stderr, "[theme] set %s -> resolved (%s) %s\n", qPrintable(key),
                     resolvedPalette_.value(key).typeName(), qPrintable(resolvedPalette_.value(key).toString()));
}

void ThemeStore::setPalette(const QVariant& values) {
    const QVariantMap in = unwrapJs(values).toMap();
    if (in.isEmpty()) return;
    QVariantMap over = settings_->uiGet("paletteOverrides", QVariantMap{}).toMap();
    for (auto it = in.constBegin(); it != in.constEnd(); ++it)
        over[it.key()] = QJsonValue::fromVariant(unwrapJs(it.value())).toVariant();
    settings_->uiSet("paletteOverrides", over);
    applyPalette();
    if (qEnvironmentVariableIsSet("MELO_THEME_DEBUG"))
        std::fprintf(stderr, "[theme] set %d roles\n", int(in.size()));
}

void ThemeStore::previewPaletteColor(const QString& key, const QVariant& value) {
    if (qEnvironmentVariableIsSet("MELO_THEME_DEBUG"))
        std::fprintf(stderr, "[theme] preview %s <- %s\n", qPrintable(key),
                     QJsonDocument::fromVariant(unwrapJs(value)).toJson(QJsonDocument::Compact).constData());
    // The same resolution applyPalette does for a stored value, so a preview
    // of "systemaccent" or a surface object looks like what saving it would give.
    auto resolve = [](const QString& color) -> QString {
        if (color == QLatin1String("systemaccent")
            || color.startsWith(QLatin1String("systemaccent:")))
            return QGuiApplication::palette().color(QPalette::Highlight).name();
        if (color.startsWith(QLatin1String("system:")))
            return systemRole(color.mid(7)).name(QColor::HexArgb);
        return color;
    };
    const QVariant v = unwrapJs(value);
    if (v.userType() == QMetaType::QVariantMap) {
        QVariantMap o = v.toMap();
        // A stack has no colour of its own; a default one would give it a
        // white top-level colour that every reader taking a single value uses.
        // Resolve what is there; add nothing that was not.
        if (o.contains("colour")) o["colour"] = resolve(o.value("colour").toString());
        resolvedPalette_[key] = o;
    } else {
        resolvedPalette_[key] = resolve(v.toString());
    }
    // the palette moved, so the palette's own signal: the interface reads
    // paletteChanged, not themeChanged
    emit paletteChanged();
    emit themeChanged();
}

// ---- presets: one part of a look, on its own --------------------------

void ThemeStore::loadUserPresets() {
    userPresets_.clear();
    for (const char* k : kPresetKinds) {
        const QString kind = QLatin1String(k);
        const QDir dir(presetsDir_ + "/" + kind);
        for (const QString& name : dir.entryList({"*.json"}, QDir::Files, QDir::Name)) {
            QFile f(dir.filePath(name));
            if (!f.open(QIODevice::ReadOnly)) continue;
            QJsonObject p = QJsonDocument::fromJson(f.readAll()).object();
            if (p["id"].toString().isEmpty()) continue;
            p["kind"] = kind;          // the folder is the authority, not the file
            p["builtIn"] = false;
            userPresets_.append(p);
        }
    }
    if (builtInPresets_.isEmpty()) builtInPresets_ = builtInPresetsFrom(builtIns_);
}

void ThemeStore::writeUserPreset(const QJsonObject& preset) {
    const QString kind = preset["kind"].toString();
    QDir().mkpath(presetsDir_ + "/" + kind);
    QSaveFile f(presetsDir_ + "/" + kind + "/" + preset["id"].toString() + ".json");
    if (!f.open(QIODevice::WriteOnly)) return;
    f.write(QJsonDocument(preset).toJson(QJsonDocument::Indented));
    f.commit();
}

QJsonObject ThemeStore::findPreset(const QString& kind, const QString& id) const {
    for (const auto& p : userPresets_)
        if (p["kind"].toString() == kind && p["id"].toString() == id) return p;
    for (const auto& p : builtInPresets_)
        if (p["kind"].toString() == kind && p["id"].toString() == id) return p;
    return {};
}

QVariantList ThemeStore::presets(const QString& kind) const {
    QVariantList out;
    auto add = [&out, &kind](const QJsonObject& p) {
        if (p["kind"].toString() != kind) return;
        out.append(QVariantMap{{"id", p["id"].toString()}, {"name", p["name"].toString()},
                               {"builtIn", p["builtIn"].toBool()}});
    };
    for (const auto& p : builtInPresets_) add(p);
    for (const auto& p : userPresets_) add(p);
    return out;
}

QString ThemeStore::savePreset(const QString& kind, const QString& name) {
    const QJsonObject body = currentBody(kind);
    if (body.isEmpty()) return {};
    const QString id = kind + QStringLiteral("-%1").arg(QDateTime::currentMSecsSinceEpoch());
    const QJsonObject p{{"id", id}, {"name", name.isEmpty() ? kind : name},
                        {"kind", kind}, {"builtIn", false}, {"body", body}};
    userPresets_.append(p);
    writeUserPreset(p);
    emit themesChanged();
    return id;
}

// every non-floating surface at v, the floating ones left as they are: the
// master opacity, since a role's own value is absolute
QVariantMap ThemeStore::masterOpacityMap(double v) const {
    QVariantMap op = mergedSettings_.value(QStringLiteral("opacity")).toMap();
    for (const QString& r : ThemeFormat::surfaceRoles())
        if (!ThemeFormat::isFloatingRole(r)) op[r] = v;
    return op;
}
void ThemeStore::setMasterOpacity(double v) {
    settings_->uiApply({{QStringLiteral("opacityScale"), v},
                        {QStringLiteral("opacity"), masterOpacityMap(v)}}, {});
}

void ThemeStore::applyPreset(const QString& kind, const QString& id) {
    const QJsonObject p = findPreset(kind, id);
    if (p.isEmpty()) return;
    const QJsonObject body = p["body"].toObject();
    if (kind == QLatin1String("layout")) { clearLayoutOverride("barMain"); settings_->uiSet("barMain", id); return; }
    if (kind == QLatin1String("palette")) {
        settings_->uiSet("paletteOverrides", body.toVariantMap());   // the whole palette, as an override
        applyPalette();
        return;
    }
    // A preset sets what it names and touches nothing else, not even inside
    // its own section. That is also what makes matchingPreset honest: a preset
    // holds when everything it asserts is true, so applying one and then
    // matching it are the same question.
    QVariantMap patch;
    const QStringList clear;
    for (const QString& k : keysFor(kind)) {
        if (!body.contains(k)) continue;
        // `background` is one object holding the type and every knob, with a
        // flat `options` bag each mode reads, so it merges: a type-only preset
        // switches the background and keeps opacity, blur, zoom and position,
        // while one saved from a real background carries every key anyway.
        if (k == QLatin1String("background")) {
            QJsonObject cur = QJsonObject::fromVariantMap(
                mergedSettings_.value(k).toMap());
            const QJsonObject next = body[k].toObject();
            for (auto it = next.begin(); it != next.end(); ++it) cur[it.key()] = it.value();
            patch[k] = cur.toVariantMap();
            continue;
        }
        patch[k] = body[k].toVariant();
    }
    // The master is every surface. A role's own opacity is absolute, so a
    // scale on its own moves nothing a theme has named — which is all of
    // them. The master slider writes the map; a preset carrying one does too.
    if (patch.contains(QStringLiteral("opacityScale")))
        patch[QStringLiteral("opacity")] =
            masterOpacityMap(patch.value(QStringLiteral("opacityScale")).toDouble());
    // the menu's own opacity, which a transparency or a scheme carries
    if (body.contains(QStringLiteral("menuOpacity"))) {
        QVariantMap op = patch.contains(QStringLiteral("opacity"))
            ? patch.value(QStringLiteral("opacity")).toMap()
            : mergedSettings_.value(QStringLiteral("opacity")).toMap();
        op[QStringLiteral("menu")] = body.value(QStringLiteral("menuOpacity")).toDouble();
        patch[QStringLiteral("opacity")] = op;
    }
    settings_->uiApply(patch, clear);
    // A preset that names a slot's layout replaces what that slot draws. The
    // slot's unsaved arrangement wins over the id it names, so it is cleared,
    // through clearLayoutOverride so what reads a slot is told (themesChanged,
    // which a patch does not send).
    for (const QLatin1String slot : { QLatin1String("barMain"), QLatin1String("barNp"), QLatin1String("barMini") })
        if (patch.contains(slot) && hasLayoutOverride(slot)) clearLayoutOverride(slot);
}

void ThemeStore::deletePreset(const QString& kind, const QString& id) {
    for (int i = 0; i < userPresets_.size(); ++i) {
        if (userPresets_[i]["kind"].toString() != kind) continue;
        if (userPresets_[i]["id"].toString() != id) continue;
        QFile::remove(presetsDir_ + "/" + kind + "/" + id + ".json");
        userPresets_.removeAt(i);
        emit themesChanged();
        return;
    }
}

// the body savePreset would store, without storing it
QJsonObject ThemeStore::currentBody(const QString& kind) const {
    if (kind == QLatin1String("palette"))
        return QJsonObject::fromVariantMap(resolvedPalette_);
    if (kind == QLatin1String("layout"))
        return QJsonObject::fromVariantMap(layoutDoc(mergedSettings_.value(QStringLiteral("barMain"), "rows").toString()));
    QJsonObject body;
    for (const QString& k : keysFor(kind))
        if (mergedSettings_.contains(k))
            body[k] = QJsonValue::fromVariant(mergedSettings_[k]);
    // ...and the menu's opacity, which those two set (see applyPreset)
    if (kind == QLatin1String("transparency") || kind == QLatin1String("scheme")) {
        const QVariantMap op = mergedSettings_.value(QStringLiteral("opacity")).toMap();
        if (op.contains(QStringLiteral("menu")))
            body[QStringLiteral("menuOpacity")] = op.value(QStringLiteral("menu")).toDouble();
    }
    return body;
}

bool ThemeStore::exportCurrent(const QString& kind, const QString& name,
                               const QString& path) {
    const QJsonObject body = currentBody(kind);
    if (body.isEmpty()) return false;
    const QJsonObject p{{"id", kind}, {"name", name.isEmpty() ? kind : name},
                        {"kind", kind}, {"builtIn", false}, {"body", body}};
    QSaveFile f(portalPath(path));
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write(QJsonDocument(p).toJson(QJsonDocument::Indented));
    return f.commit();
}

// Does everything this preset asserts still hold? A subset test, recursing
// into nested objects (`background`): a type-only preset still matches after
// an opacity change, while one saved from a real background stops matching
// when any captured key moves.
static bool holds(const QJsonObject& want, const QJsonObject& have) {
    for (auto it = want.begin(); it != want.end(); ++it) {
        const QJsonValue mine = have.value(it.key());
        if (it.value().isObject() && mine.isObject()) {
            if (!holds(it.value().toObject(), mine.toObject())) return false;
        } else if (mine != it.value()) return false;
    }
    return true;
}

// The packaged family: shipped in assets/fonts, so it is the one thing that
// is always here.
static const char* kDefaultFont = "Red Hat Display";

bool ThemeStore::hasFont(const QString& family) const {
    if (family.isEmpty()) return false;
    if (fontFamilies_.isEmpty()) {
        const QStringList all = QFontDatabase::families();
        for (const QString& f : all) fontFamilies_.insert(f);
    }
    return fontFamilies_.contains(family);
}

QString ThemeStore::resolveFont(const QString& family) const {
    return hasFont(family) ? family : QString::fromLatin1(kDefaultFont);
}

QString ThemeStore::matchingPreset(const QString& kind) const {
    // A palette preset stores the theme's RAW palette, tokens and all
    // ("systemaccent:#cc3333"), so it has to be compared against the raw one —
    // resolvedPalette_ has already turned those into colours and would never
    // match a built-in.
    const QJsonObject body = kind == QLatin1String("palette")
        ? findTheme(activeId_)["palette"].toObject()
        : currentBody(kind);
    if (body.isEmpty()) return {};
    // A slot that has been arranged is not the layout it names, so no player
    // preset holds while one carries an unsaved arrangement: applying a preset
    // drops those, and matching one asks the same question the other way.
    if (kind == QLatin1String("player"))
        for (const QLatin1String slot : { QLatin1String("barMain"), QLatin1String("barNp"), QLatin1String("barMini") })
            if (hasLayoutOverride(slot)) return {};

    // The most specific match wins: with a bare "Starfield" and a fully
    // tuned "Midnight Stars" both holding, the one that asserts more is the
    // one you are looking at.
    QString best;
    int bestScore = -1;
    auto consider = [&](const QList<QJsonObject>& from) {
        for (const auto& p : from) {
            if (p["kind"].toString() != kind) continue;
            const QJsonObject want = p["body"].toObject();
            if (want.isEmpty() || !holds(want, body)) continue;
            int score = 0;
            for (auto it = want.begin(); it != want.end(); ++it)
                score += it.value().isObject() ? it.value().toObject().size() : 1;
            if (score > bestScore) { bestScore = score; best = p["id"].toString(); }
        }
    };
    consider(builtInPresets_);
    consider(userPresets_);      // yours wins a tie, being considered last
    return best;
}

QString ThemeStore::importPreset(const QString& path) {
    QFile f(portalPath(path));
    if (!f.open(QIODevice::ReadOnly)) return {};
    QJsonObject p = QJsonDocument::fromJson(f.readAll()).object();
    const QString kind = p["kind"].toString();
    if (!isPresetKind(kind)) return {};
    if (p["body"].toObject().isEmpty()) return {};
    p["id"] = kind + QStringLiteral("-%1").arg(QDateTime::currentMSecsSinceEpoch());
    p["builtIn"] = false;
    if (p["name"].toString().isEmpty()) p["name"] = kind;
    userPresets_.append(p);
    writeUserPreset(p);
    emit themesChanged();
    return p["id"].toString();
}

void ThemeStore::writeUserTheme(const QJsonObject& theme) {
    QDir().mkpath(themesDir_);
    QSaveFile f(themesDir_ + "/" + theme["id"].toString() + ".json");
    if (!f.open(QIODevice::WriteOnly)) return;
    f.write(QJsonDocument(theme).toJson(QJsonDocument::Indented));
    f.commit();
}

bool ThemeStore::isBuiltInLayout(const QString& id) const {
    for (const char* b : kBuiltInLayoutIds) if (id == QLatin1String(b)) return true;
    return false;
}

QVariantMap ThemeStore::layoutDoc(const QString& id) const {
    if (isBuiltInLayout(id)) return builtInLayout(id).toVariantMap();
    const QJsonObject p = findPreset(QStringLiteral("layout"), id);
    if (!p.isEmpty()) return p["body"].toObject().toVariantMap();
    return builtInLayout(QStringLiteral("rows")).toVariantMap();   // a slot naming a layout that is gone
}

QString ThemeStore::saveLayoutDoc(const QVariantMap& doc, const QString& name) {
    const QString id = QStringLiteral("layout-%1").arg(QDateTime::currentMSecsSinceEpoch());
    QJsonObject body = QJsonObject::fromVariantMap(unwrapJs(doc).toMap());
    body["id"] = id;
    body["name"] = name.isEmpty() ? QStringLiteral("Layout") : name;
    const QJsonObject p{{"id", id}, {"name", body["name"]}, {"kind", "layout"}, {"builtIn", false}, {"body", body}};
    userPresets_.append(p);
    writeUserPreset(p);
    emit themesChanged();
    return id;
}

void ThemeStore::setLayoutDoc(const QString& id, const QVariantMap& doc) {
    for (auto& p : userPresets_) {
        if (p["kind"].toString() != QLatin1String("layout") || p["id"].toString() != id) continue;
        QJsonObject body = QJsonObject::fromVariantMap(unwrapJs(doc).toMap());
        body["id"] = id;
        body["name"] = p["name"];
        p["body"] = body;
        writeUserPreset(p);
        emit themesChanged();
        return;
    }
}

QVariantMap ThemeStore::layoutOverride(const QString& slot) const {
    return settings_->uiGet("layoutOverrides", QVariantMap{}).toMap().value(slot).toMap();
}
bool ThemeStore::hasLayoutOverride(const QString& slot) const { return !layoutOverride(slot).isEmpty(); }
void ThemeStore::setLayoutOverride(const QString& slot, const QVariantMap& doc) {
    QVariantMap all = settings_->uiGet("layoutOverrides", QVariantMap{}).toMap();
    all[slot] = QJsonObject::fromVariantMap(unwrapJs(doc).toMap()).toVariantMap();
    settings_->uiSet("layoutOverrides", all);
    emit themesChanged();   // what draws a document re-reads it
}
void ThemeStore::clearLayoutOverride(const QString& slot) {
    QVariantMap all = settings_->uiGet("layoutOverrides", QVariantMap{}).toMap();
    all[slot] = QVariantMap{};   // a removal never reaches the sidecar; empty reads as none
    settings_->uiSet("layoutOverrides", all);
    emit themesChanged();
}

bool ThemeStore::anyLayoutOverride() const {
    for (const QLatin1String slot : { QLatin1String("barMain"), QLatin1String("barNp"), QLatin1String("barMini") })
        if (hasLayoutOverride(slot)) return true;
    return false;
}

// A saved theme keeps its arranged bars: it stores a slot's layout id, and
// saving re-applies the theme and drops unsaved arrangements, so each is saved
// to a layout first. Layouts are shared by every theme naming them, so one
// used by another theme (or a built-in) gets a new layout named for this one.
bool ThemeStore::layoutUsedElsewhere(const QString& layoutId, const QString& ownerThemeId) const {
    const auto names = [&](const QJsonObject& t) {
        if (t["id"].toString() == ownerThemeId) return false;
        const QJsonObject ts = themeSettingsOf(t);
        for (const char* slot : {"barMain", "barNp", "barMini"})
            if (ts[QLatin1String(slot)].toString() == layoutId) return true;
        return false;
    };
    for (const QJsonObject& t : userThemes_) if (names(t)) return true;
    for (const QJsonObject& t : builtIns_) if (names(t)) return true;
    return false;
}

void ThemeStore::foldLayoutOverrides(const QString& ownerThemeId, const QString& themeName) {
    QVariantMap patch;
    QVariantMap all = settings_->uiGet("layoutOverrides", QVariantMap{}).toMap();
    for (const QLatin1String slot : { QLatin1String("barMain"), QLatin1String("barNp"), QLatin1String("barMini") }) {
        const QVariantMap doc = layoutOverride(slot);
        if (doc.isEmpty()) continue;
        QString lid = doc.value(QStringLiteral("id")).toString();
        const bool own = !lid.isEmpty() && !isBuiltInLayout(lid)
                         && !findPreset(QStringLiteral("layout"), lid).isEmpty()
                         && !layoutUsedElsewhere(lid, ownerThemeId);
        if (own) {
            setLayoutDoc(lid, doc);
        } else {
            const QString base = themeName.isEmpty() ? doc.value(QStringLiteral("name")).toString() + QStringLiteral(" Custom") : themeName;
            const QString suffix = slot == QLatin1String("barNp") ? QStringLiteral(" now playing")
                                 : slot == QLatin1String("barMini") ? QStringLiteral(" mini") : QString();
            lid = saveLayoutDoc(doc, base + suffix);
        }
        patch[slot] = lid;
        all[slot] = QVariantMap{};
    }
    if (patch.isEmpty()) return;
    patch[QStringLiteral("layoutOverrides")] = all;
    settings_->uiApply(patch, {});
    emit themesChanged();
}

QString ThemeStore::forkLayout(const QString& id, const QString& name) {
    const QVariantMap doc = layoutDoc(id);
    return saveLayoutDoc(doc, name.isEmpty() ? doc.value("name").toString() + QStringLiteral(" Custom") : name);
}

void ThemeStore::renamePreset(const QString& kind, const QString& id, const QString& name) {
    if (name.isEmpty()) return;
    for (auto& p : userPresets_) {
        if (p["kind"].toString() != kind || p["id"].toString() != id) continue;
        p["name"] = name;
        if (kind == QLatin1String("layout")) { QJsonObject b = p["body"].toObject(); b["name"] = name; p["body"] = b; }
        writeUserPreset(p);
        emit themesChanged();
        return;
    }
}

// Export what is on the bar, saved or not, as a layout file
bool ThemeStore::exportLayoutDoc(const QVariantMap& doc, const QString& path) {
    QJsonObject body = QJsonObject::fromVariantMap(unwrapJs(doc).toMap());
    const QJsonObject p{{"id", body["id"].toString().isEmpty() ? QStringLiteral("layout") : body["id"].toString()},
                        {"name", body["name"].toString().isEmpty() ? QStringLiteral("Layout") : body["name"].toString()},
                        {"kind", "layout"}, {"builtIn", false}, {"body", body}};
    QSaveFile f(portalPath(path));
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write(QJsonDocument(p).toJson(QJsonDocument::Indented));
    return f.commit();
}
