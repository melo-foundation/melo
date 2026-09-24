#pragma once

#include "SkinImageProvider.h"

#include <QByteArray>
#include <QHash>
#include <QJsonArray>
#include <QObject>
#include <QString>
#include <QStringList>

#include <functional>
#include <memory>
#include <mutex>

class SkinArchive;

// The container SkinImageProvider's resolver reads, on Qt's pixmap reader
// thread (tst_skinarchive::asynchronousQmlLoadRunsOffTheGuiThread) while the
// GUI thread inserts on a skin change. The mutex covers only the lookup and the
// shared_ptr copy, never a decode; archives are immutable once copied out.
// Shared with the resolver lambda, so a request in flight during teardown finds
// an empty store rather than a freed one.
class PluginArchiveStore {
public:
    explicit PluginArchiveStore(QString pluginId) : id_(std::move(pluginId)) {}

    // Called on Qt's image loader thread, with an ATTACKER-CHOSEN, UNNORMALIZED
    // pluginId: it is whatever the plugin's QML put in a source url, and ".."
    // arrives intact (tst_skinarchive::dotDotInAnIdReachesTheResolverUnnormalized).
    // It is compared, never joined into anything — an exact match against the
    // id this store was built for, or nothing.
    std::shared_ptr<const SkinArchive> lookup(const QString& pluginId,
                                              const QString& settingsKey) const;

    // GUI thread. A null archive removes the key, so a skin the user cleared
    // stops serving pixels instead of serving the previous one forever.
    void put(const QString& settingsKey, std::shared_ptr<const SkinArchive> archive);

private:
    const QString id_;
    mutable std::mutex mutex_;
    QHash<QString, std::shared_ptr<const SkinArchive>> byKey_;
};

// One settings key's archive, as plugin QML sees it. Everything on it is a
// name inside the archive; nothing takes, returns or accepts a path. `ready`
// and `error` are captured from the shell's load (SkinArchive has neither).
class MeloUiArchive : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QStringList names READ names NOTIFY changed)
    // Changes on every adopt. QML drops a re-evaluation that yields the same
    // value, and a new archive often leaves ready/error/names unchanged, so a
    // binding that reads text() must mention `generation` to see a replaced
    // file. image() puts it in the url's cache-busting fragment.
    Q_PROPERTY(uint generation READ generation NOTIFY changed)
public:
    bool ready() const { return archive_ != nullptr; }
    QString error() const { return error_; }
    QStringList names() const;
    uint generation() const { return generation_; }

    // A source url for `name`, or an EMPTY STRING when the archive holds no
    // such entry — an absent entry never produces a url, so a plugin cannot
    // turn image() into an oracle for anything outside the archive. Lookup is
    // case-folded, like the archive's own.
    Q_INVOKABLE QString image(const QString& name) const;

    // The entry's text, or an empty string. Text comes back by VALUE rather
    // than as a url: there is no image-provider equivalent for text, and a
    // second url scheme would be a second place to get the grammar wrong.
    Q_INVOKABLE QString text(const QString& name) const;

    // One pixel from an image inside the archive, as #rrggbb. Classic skins
    // encode their title colour in text.bmp itself; sampling its known A-glyph
    // ink lets a Unicode replacement keep the skin's colour. No path is
    // accepted, and an absent image/out-of-range coordinate returns empty.
    Q_INVOKABLE QString pixel(const QString& name, int x, int y) const;

signals:
    void changed();

private:
    friend class MeloUiArchives;
    MeloUiArchive(QString pluginId, QString settingsKey, QObject* parent);

    // Private with MeloUiArchives as friend: this object is plugin-reachable,
    // and a private non-invokable setter stays out of QML's reach.
    void adopt(std::shared_ptr<const SkinArchive> archive, QString error);

    const QString pluginId_, key_;
    std::shared_ptr<const SkinArchive> archive_;
    QString error_;
    QString loadedFrom_;      // the settings VALUE this archive was loaded from
    bool haveLoaded_ = false; // distinguishes "never resolved" from "resolved to nothing"
    // Unsigned because a plugin can drive this by writing its own setting in a
    // loop, and signed overflow is undefined behaviour while unsigned wrap is
    // defined. A wrapped
    // generation repeats a url a plugin stopped using 4 billion reloads ago.
    unsigned generation_ = 0;   // see image(): the url's cache-busting fragment
};

// MeloUi.archives; the whole API is get(). No API accepts a path: a plugin names
// a `file` settings key its manifest declared, and the shell resolves it inside
// the plugin's data dir with pluginSettingFiles()'s containment check. The three
// plugin inputs (key, entry name, hand-written image:// url) are each checked
// against names the plugin did not write.
//
// Keep out: enumerating or adding keys, and revealing where a file lives. An
// undeclared key returns null, so asking in a loop cannot grow memory.
class MeloUiArchives : public QObject {
    Q_OBJECT
public:
    // valueOf: the file the user picked for a key, from the live settings bag.
    // A std::function so tst_plugincontainment can link this without MeloUiSettings.
    using ValueGetter = std::function<QString(const QString& settingsKey)>;

    MeloUiArchives(QString pluginId, ValueGetter valueOf, QObject* parent = nullptr);

    // Null for a key the manifest never declared as a `file` field (including
    // any path attempt); otherwise the same facade every time, so a plugin's
    // bindings survive reloads. Ownership is set to C++ explicitly: a returned
    // parentless QObject* gets JavaScriptOwnership, and a plugin calling gc()
    // would free a facade the shell still writes to.
    Q_INVOKABLE QObject* get(const QString& settingsKey);

    // --- shell only. Neither Q_INVOKABLE nor slots, so QML cannot resolve them
    // (the same rule that keeps MeloUiSettings::refresh() out of a plugin's
    // reach). A plugin installing its own schema would BE the traversal. ---

    // The plugin's validated manifest `settings` array, as melo received it
    // from the sidecar. Only `file` fields are kept; everything else about a
    // field is ignored here.
    void setSchema(const QJsonArray& settings);

    // Re-resolve every key a plugin has already opened. Cheap when nothing
    // moved: a key whose settings value is unchanged is not reloaded.
    void refresh();

    // The resolver for SkinImageProvider; holds the store by shared_ptr, so it
    // outlives this object. Serves only keys get() has opened: loading on demand
    // would read settings and disk on the image loader thread.
    SkinImageProvider::Resolver resolver() const;

private:
    struct FileField {
        QString dir;              // relative to the plugin's data dir; may be empty
        QStringList extensions;   // lower-cased, no leading dot; empty means "any"
    };

    // The security boundary, in one function. Returns the FILE'S BYTES — never
    // a path, because a path has to be reopened by name and a name can be
    // re-pointed between the check and the open. False with *error set on
    // every refusal. See the definition for what it refuses.
    bool readFileForKey(const QString& settingsKey, const QString& value,
                        QByteArray* bytes, QString* error) const;

    // Open once, then verify the descriptor that was opened. `root` must
    // already be canonical; `label` is the only caller-supplied string allowed
    // into *error, so it is the bare settings value and never a path.
    static bool readVerifiedFile(const QString& path, const QString& root,
                                 const QString& label, QByteArray* bytes,
                                 QString* error);

    void reload(const QString& settingsKey, MeloUiArchive* facade);

    const QString id_;
    const QString dataRoot_;      // <config>/plugin-data/<pluginId>
    const ValueGetter valueOf_;
    QHash<QString, FileField> fields_;
    QHash<QString, MeloUiArchive*> facades_;
    const std::shared_ptr<PluginArchiveStore> store_;
};
