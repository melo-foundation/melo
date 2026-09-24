#pragma once
#include <QJsonObject>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class SettingsStore;

// Theme system backend; the role model is at the top of ThemeStore.cpp, the
// format in ThemeFormat. Built-in themes are compiled in; user themes are
// <config>/melo/themes/<id>.json; the active id is ui.activeThemeId. QML's
// `Theme` singleton binds to the resolved palette/settings maps exposed
// here; components never read colours from ThemeStore directly.
// "systemaccent:#fallback" resolves to the OS accent (QPalette highlight,
// fed by the portal on Plasma/GNOME).
class ThemeStore : public QObject {
    Q_OBJECT
    // The palette and the settings change separately, so a window-radius
    // edit does not re-resolve every surface and ink and rebuild every fill.
    Q_PROPERTY(QVariantMap palette READ palette NOTIFY paletteChanged)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(QString activeId READ activeId NOTIFY themeChanged)
    Q_PROPERTY(QString activeName READ activeName NOTIFY themeChanged)
    Q_PROPERTY(bool activeBuiltIn READ activeBuiltIn NOTIFY themeChanged)
    // Custom is a state: the active theme with edits over it that no file
    // holds — palette overrides, or a setting of a part the theme has that
    // differs from it. Save as theme writes a file; Discard drops the edits.
    Q_PROPERTY(bool dirty READ dirty NOTIFY themeChanged)
    Q_PROPERTY(QVariantList themes READ themes NOTIFY themesChanged)
    // Why the last importTheme() returned nothing. QML shows it rather than
    // leaving a refused import looking like a click that did not register.
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit ThemeStore(SettingsStore* settings, QObject* parent = nullptr);

    // The desktop changed its colours — re-resolve. See the System theme in
    // ThemeStore.cpp: its palette is sentinels, so it is only ever as current
    // as the last time this ran.
    bool eventFilter(QObject* obj, QEvent* ev) override;

    QVariantMap palette() const { return resolvedPalette_; }
    QVariantMap settings() const { return mergedSettings_; }
    QString activeId() const { return activeId_; }
    QString activeName() const;
    bool activeBuiltIn() const;
    QVariantList themes() const;   // [{id, name, builtIn}]

    // selecting a theme COPIES its settings into the live
    // settings blob (ui.*); appearance edits afterwards are standalone
    Q_INVOKABLE void setActive(const QString& id);
    // the parts of a theme to take: with "palette" among them the theme
    // becomes the active one, without it the parts land on the current
    // theme; a part not taken keeps its values through the switch
    Q_INVOKABLE void applyThemeParts(const QString& id, const QStringList& parts);
    Q_INVOKABLE QStringList themeParts() const;   // every part, in order
    Q_INVOKABLE QStringList partsOfTheme(const QString& id) const;   // the parts a theme has
    // One part at a time: whether it differs from the active theme's — an
    // edit, or another theme's preset over it — and the way back. A part the
    // theme lacks is measured against the defaults, which is what the theme
    // draws for it. The palette is asked by roles: a section owns some.
    Q_INVOKABLE bool partDirty(const QString& part) const;
    Q_INVOKABLE void discardPart(const QString& part);
    Q_INVOKABLE bool rolesDirty(const QStringList& roles, bool others = false) const;
    Q_INVOKABLE void discardRoles(const QStringList& roles, bool others = false);
    // the active theme's own entry for a role, before any edit; invalid when
    // the theme does not name it
    Q_INVOKABLE QVariant themeEntry(const QString& role) const;
    bool dirty() const { return dirty_; }
    Q_INVOKABLE void discard();
    // Save as theme with a choice per part: "own" (kept) or "off" (left
    // out). A part kept that is identical to a built-in theme's part is
    // written as a pointer to that built-in, not asked about.
    Q_INVOKABLE QString saveThemeAs(const QString& name, const QVariantMap& choices);
    // the edits since, written into the active theme's own file; a built-in
    // cannot be, and says so by doing nothing
    Q_INVOKABLE bool saveActive();
    // the built-in whose part the current values equal, or empty
    Q_INVOKABLE QString builtInMatching(const QString& part) const;
    QJsonObject themeSettingsOf(const QJsonObject& theme) const;
    Q_INVOKABLE void deleteTheme(const QString& id);
    // a theme is already the whole look — palette plus every appearance key,
    // background included — so export is that object on disk
    Q_INVOKABLE bool exportTheme(const QString& id, const QString& path);
    Q_INVOKABLE QString importTheme(const QString& path);

    // An SVG as a glyph entry: {ok: true, entry: {vb, ink, fill, sw, paths}}
    // or {ok: false, error} — the settings row shows the error as it is.
    Q_INVOKABLE QVariantMap importGlyph(const QString& path) const;

    // The swatches a theme travels with. An entry applied from a swatch keeps
    // its id as `from`, and a saved or exported theme inlines the ones its
    // roles were stamped with; the shelf shows them and copies one on request.
    // Edits are an override in ui.themeSwatches: read here while set, written
    // by Save as theme and Export (union by id), dropped by Discard or a switch.
    Q_INVOKABLE QVariantList themeSwatches(const QString& id = {}) const;
    Q_INVOKABLE void setThemeSwatches(const QVariantList& list);

    // ---- parts -----------------------------------------------------------
    // A preset is one part of a look (kPresetKinds in ThemeStore.cpp), saved,
    // listed, applied, exported and deleted on its own. Applying one leaves
    // the other parts as they were.
    Q_INVOKABLE QVariantList presets(const QString& kind) const;  // [{id,name,builtIn}]
    Q_INVOKABLE QString savePreset(const QString& kind, const QString& name);
    Q_INVOKABLE void applyPreset(const QString& kind, const QString& id);
    Q_INVOKABLE void deletePreset(const QString& kind, const QString& id);
    Q_INVOKABLE bool exportCurrent(const QString& kind, const QString& name,
                                   const QString& path);
    Q_INVOKABLE QString importPreset(const QString& path);   // kind is in the file
    // Which preset, if any, this section currently IS. Compared by value, so
    // it stops naming one the moment you change something in that section
    // rather than claiming to still be it.
    Q_INVOKABLE QString matchingPreset(const QString& kind) const;
    QVariantMap masterOpacityMap(double v) const;

    // A theme carries a font by NAME, so a shared one names a family the
    // machine opening it may not have. Qt substitutes silently, which is the
    // worst of the options: the theme looks wrong and never says so.
    Q_INVOKABLE bool hasFont(const QString& family) const;
    // the family if it is here, otherwise the one melo ships
    Q_INVOKABLE QString resolveFont(const QString& family) const;
    // live appearance edit (writes ui.<key>, applies immediately)
    Q_INVOKABLE void setThemeSetting(const QString& key, const QVariant& value);
    // The master opacity: a role's own opacity is absolute, so this writes
    // opacityScale and sets every non-floating surface to it in one patch. A
    // transparency preset carrying a scale goes the same way (see applyPreset).
    Q_INVOKABLE void setMasterOpacity(double v);
    // palette edit, an override in ui.paletteOverrides until Save as theme:
    // a colour string, or a surface object {colour, source, blend, amounts}
    Q_INVOKABLE void setPaletteColor(const QString& key, const QVariant& value);
    // Many roles, one write. A recolour in Simple mode touches every role a
    // colour appears in; one setPaletteColor each is a settings write and an
    // applyPalette cascade per role, and the interface repaints through all of
    // them. The keys given are merged over the overrides already there.
    Q_INVOKABLE void setPalette(const QVariant& values);
    // ---- bar layouts -------------------------------------------------------
    // A layout is a preset of kind "layout" whose body is a document
    // (docs/bar-layout.md): the four built-ins (rows, centre, strip,
    // ministrip) and any saved. A slot key (barMain, barNp, barMini) names one by id.
    Q_INVOKABLE QVariantMap layoutDoc(const QString& id) const;
    Q_INVOKABLE QString saveLayoutDoc(const QVariantMap& doc, const QString& name);   // a new custom layout
    Q_INVOKABLE void setLayoutDoc(const QString& id, const QVariantMap& doc);         // rewrite a custom one
    Q_INVOKABLE QString forkLayout(const QString& id, const QString& name);           // a copy, custom
    Q_INVOKABLE bool isBuiltInLayout(const QString& id) const;
    bool anyLayoutOverride() const;
    // A slot's unsaved layout: arranging edits a document that no file holds,
    // kept in ui.layoutOverrides by slot, until Save writes it. As Custom is
    // for a theme.
    Q_INVOKABLE QVariantMap layoutOverride(const QString& slot) const;
    Q_INVOKABLE bool hasLayoutOverride(const QString& slot) const;
    Q_INVOKABLE void setLayoutOverride(const QString& slot, const QVariantMap& doc);
    Q_INVOKABLE void clearLayoutOverride(const QString& slot);
    Q_INVOKABLE bool exportLayoutDoc(const QVariantMap& doc, const QString& path);   // as a layout file
    Q_INVOKABLE void renamePreset(const QString& kind, const QString& id, const QString& name);
    // While the picker is open. setPaletteColor is a settings write, so
    // driving it from a drag would be a write per mouse move. This moves the
    // resolved palette only: the interface repaints and nothing is saved.
    Q_INVOKABLE void previewPaletteColor(const QString& key, const QVariant& value);

    QString lastError() const { return lastError_; }

    // The role model, for QML and for tests. Static: they describe the
    // format, not a store.
    Q_INVOKABLE static QStringList surfaceRoles();
    Q_INVOKABLE static bool isSurfaceRole(const QString& key);
    Q_INVOKABLE static bool isFloatingRole(const QString& key);

signals:
    void themeChanged();
    void paletteChanged();
    void settingsChanged();
    void themesChanged();
    // the theme's swatches, as edited — no appearance key moves, so neither
    // of the two above fires for them
    void themeSwatchesChanged();

    void lastErrorChanged();
private:
    void foldLayoutOverrides(const QString& ownerThemeId, const QString& themeName);
    bool layoutUsedElsewhere(const QString& layoutId, const QString& ownerThemeId) const;
    QString lastError_;
    QJsonObject findTheme(const QString& id) const;
    void loadUserThemes();
    void applyPalette();
    void rebuildSettings();
    void writeUserTheme(const QJsonObject& theme);

    SettingsStore* settings_;
    QString themesDir_;
    QString presetsDir_;
    QList<QJsonObject> userPresets_;      // each carries its own "kind"
    QList<QJsonObject> builtInPresets_;
    void loadUserPresets();
    void writeUserPreset(const QJsonObject& preset);
    QJsonObject findPreset(const QString& kind, const QString& id) const;
    QJsonObject currentBody(const QString& kind) const;
    mutable QSet<QString> fontFamilies_;   // enumerating them is not cheap
    QJsonObject defaults_;            // defaultSettingsJson()
    QList<QJsonObject> builtIns_;
    QList<QJsonObject> userThemes_;
    QString activeId_;
    bool dirty_ = false;
    QVariantMap resolvedPalette_;
    bool paletteQueued_ = false;   // an apply is already on the event loop
    QVariantMap mergedSettings_;      // defaults <- theme.settings <- ui.*
};
