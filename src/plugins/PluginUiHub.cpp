#include "PluginUiHub.h"

#include "PluginUiHost.h"

PluginUiHub::PluginUiHub(QObject* parent) : QObject(parent) {}

void PluginUiHub::add(const QString& id, PluginUiHost* host) {
    if (!id.isEmpty() && host) hosts_.insert(id, host);
}

void PluginUiHub::clear() { hosts_.clear(); }

bool PluginUiHub::has(const QString& pluginId) const {
    return !hosts_.value(pluginId).isNull();
}

bool PluginUiHub::invokeAction(const QString& pluginId, const QString& key) {
    PluginUiHost* h = hosts_.value(pluginId);
    return h ? h->invokeAction(key) : false;
}

bool PluginUiHub::invokeCommand(const QString& pluginId, const QString& id) {
    PluginUiHost* h = hosts_.value(pluginId);
    return h ? h->invokeCommand(id) : false;
}

bool PluginUiHub::invokeIntercept(const QString& pluginId, const QString& id) {
    PluginUiHost* h = hosts_.value(pluginId);
    return h ? h->invokeIntercept(id) : false;
}

void PluginUiHub::refreshSettings(const QString& pluginId) {
    if (PluginUiHost* h = hosts_.value(pluginId)) h->refreshSettings();
}
