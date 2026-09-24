#pragma once
#include "SkinImageProvider.h"

#include <QObject>
#include <QString>
#include <QQmlEngine>
#include <QQuickItem>
#include <functional>
#include <memory>

// Hosts one ui plugin's QML in its own QQmlEngine. Containment is three
// mechanisms, all required:
//   1. import path curated to meloPluginImportDir(): Qt.labs.*,
//      QtQuick.LocalStorage and QtQuick.Dialogs do not resolve. This gates
//      file-resolved imports only. qmlRegisterType is process-global, so a
//      plugin can `import Melo 1.0` here; a C++-registered URI that exposes
//      anything sensitive must compare qmlEngine(this) with the main engine
//      and refuse itself.
//   2. no context properties except the MeloUi bridge (and `Plugin`, the
//      plugin's own entry root).
//   3. melo's own objects are not named in this engine. This says nothing
//      about reachability: the plugin root's `parent` is a shell-owned gate
//      item (`parent.visible = true` re-shows a silenced window), and
//      `Window.window.transientParent` reaches melo's main window. No route
//      from there to melo's objects has been searched for.
//
// The main engine cannot be reused: it needs the full import set, and a
// shadowed context property is reachable through `parent` in zero hops.
//
// Deleting JS globals does not work on Qt 6.10
// (globalObject().deleteProperty("XMLHttpRequest")); build nothing on it.
class PluginUiHost : public QObject {
    Q_OBJECT
    // Read by melo's OWN settings window (main engine) to tell whose QML is
    // loaded. Plugin QML never sees this object — its engine gets MeloUi only.
    Q_PROPERTY(QString pluginId READ pluginId CONSTANT)
public:
    PluginUiHost(QString pluginId, QString pluginDir, QObject* bridge, QObject* parent = nullptr);
    ~PluginUiHost() override;

    QString pluginId() const { return id_; }

    // An `action` settings field emits the same-named signal on entry.qml's
    // root. `key` comes from the plugin's validated manifest schema. false when
    // the plugin's QML is not loaded (only while it holds `ui`) or the root
    // declares no such signal/function; do not render an undeliverable action.
    Q_INVOKABLE bool invokeAction(const QString& key);

    // A command id is the argument of entry.qml's `function command(id)`, never a
    // zero-arg method of that name (id `destroyed` would emit QObject::destroyed).
    // Accepts both `command(QVariant)` (untyped) and `command(QString)`. false
    // when the plugin's QML is not loaded or the root declares neither.
    bool invokeCommand(const QString& id);

    // Same lookup as invokeCommand, for entry.qml's `function intercept(id)`.
    // Intercept ids are catalog actions (`play`, …), never settings schema keys.
    bool invokeIntercept(const QString& id);

    // `plugins/setSetting` broadcasts nothing, so the settings page calls this
    // after an acknowledged write to push the value into the running plugin; the
    // bridge's seq ordering decides what the reply may overwrite. A
    // std::function, because naming MeloUi here (even in a qobject_cast) breaks
    // tst_plugincontainment's link, which cannot pull in the sidecar world.
    void setSettingsRefresher(std::function<void()> fn) { refresher_ = std::move(fn); }
    Q_INVOKABLE void refreshSettings();

    // Registers the archive image provider on this plugin's engine only. Never
    // give it to the main engine: every plugin's decoded skin would be one
    // `image://plugin-archive/...` url from melo's QML and other plugins. Pinned
    // by tst_plugincontainment::archiveProviderIsPerEngineNotProcessGlobal.
    // The resolver is injected so this header stays linkable without the owner
    // of plugin settings. A second call is ignored: Qt would delete the first
    // provider while a loader thread may still be inside it.
    void installArchiveProvider(SkinImageProvider::Resolver resolver);

    // Instantiates entry.qml (a non-visual root holding cross-window state).
    // Pass an empty string for a plugin that declares no entry.qml.
    bool load(const QString& entryQmlRel);

    // Null when the curated import dir was missing — construction fails closed
    // rather than building an engine on the system import path.
    QQmlEngine* engine() const { return engine_.get(); }
    QObject* pluginRoot() const { return root_.get(); }
    QString errorString() const { return error_; }

    // Instantiates one window's QML. windowParent is this plugin's QQuickWindow
    // (its contentItem() is used) or a QQuickItem; an object from another engine
    // is rejected. Null means create without attaching. A non-null parent a
    // visual root cannot attach to returns nullptr.
    //
    // The host owns every returned object (QObject parent == this), whatever
    // the visual parent, and destroys it before the engine. Delete the returned
    // object to close one window early.
    QObject* createWindowContent(const QString& qmlRel, QObject* windowParent);

    // A slot occupant: the same instantiation, into an item in melo's window.
    //
    // An unavoidable hole in (3): drawing melo's chrome means sitting in melo's
    // visual parent chain, so a slot occupant can walk `parent` to melo's items,
    // read their properties and call their methods in melo's context. A `ui`
    // grant already allows playback, chrome takeover, intercepts, gestures and
    // hiding melo's window, but that surface is enumerated and tested, while a
    // parent walk grows with every function added to Main.qml. No lint can
    // guard it. Before third-party plugins, this needs offscreen rendering of
    // the occupant or a grant that says the plugin controls melo's interface.
    //
    // `qml` may be relative to the plugin dir or absolute.
    QObject* createSlotContent(const QString& qml, QQuickItem* slotGate);

private:
    // Shared by invokeCommand / invokeIntercept. `method` is "command" or
    // "intercept". Refuses QObject names via indexOfMethod(id+"()") on
    // QObject's meta-object, not the plugin root.
    bool invokeIdHandler(const char* method, const QString& id);

    QString id_, dir_, error_;
    bool archiveProviderInstalled_ = false;
    std::function<void()> refresher_;
    std::unique_ptr<QQmlEngine> engine_;
    std::unique_ptr<QObject> root_;
};
