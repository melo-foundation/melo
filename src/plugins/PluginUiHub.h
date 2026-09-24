#pragma once
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QString>

class PluginUiHost;

// One `PluginUi` context property for every plugin whose QML is loaded, keyed by
// plugin id: with a single host, plugin A's settings-page action would fire on
// whichever plugin melo built last, so every call names its plugin.
//
// Does not own the hosts (main.cpp does) and never hands one to QML; the plugin
// id always comes from melo's side of the seam.
class PluginUiHub : public QObject {
    Q_OBJECT
public:
    explicit PluginUiHub(QObject* parent = nullptr);

    void add(const QString& id, PluginUiHost* host);
    void clear();
    // Shell-side only: main.cpp names the hub to QML only when it answers for
    // something, so `PluginUi` stays null rather than becoming a non-null object
    // that says no to every plugin.
    bool isEmpty() const { return hosts_.isEmpty(); }

    // Whether that plugin's entry.qml is loaded right now. The settings page
    // renders an `action` row only when this is true — a button that cannot
    // deliver is not shown at all rather than shown dead.
    Q_INVOKABLE bool has(const QString& pluginId) const;
    // false when the plugin is not loaded or its root declares no such
    // signal/function; `key` always comes from the plugin's own validated
    // manifest schema.
    Q_INVOKABLE bool invokeAction(const QString& pluginId, const QString& key);
    // Entry.qml `function command(id)`. `id` is a command id, not a schema key.
    // false when the plugin is not loaded.
    Q_INVOKABLE bool invokeCommand(const QString& pluginId, const QString& id);
    // Entry.qml `function intercept(id)`. Intercept ids are catalog actions
    // (`play`, …), never settings schema keys. false when the plugin is not loaded.
    Q_INVOKABLE bool invokeIntercept(const QString& pluginId, const QString& id);
    // Push a settings write melo just made into the RUNNING plugin. No-op for a
    // plugin that is not loaded.
    Q_INVOKABLE void refreshSettings(const QString& pluginId);

private:
    // QPointer: the hosts are torn down by a rebuild, and plugin QML can reach
    // a route that triggers one — a stale raw pointer here would be a
    // use-after-free reached from a settings button.
    QHash<QString, QPointer<PluginUiHost>> hosts_;
};
