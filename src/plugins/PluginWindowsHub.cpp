#include "PluginWindowsHub.h"

#include "PluginWindowHost.h"

PluginWindowsHub::PluginWindowsHub(QObject* parent) : QObject(parent) {}

void PluginWindowsHub::add(PluginWindowHost* host) {
    if (host) hosts_.append(host);
}

void PluginWindowsHub::clear() { hosts_.clear(); }

bool PluginWindowsHub::isEmpty() const { return hosts_.isEmpty(); }

void PluginWindowsHub::setActive(bool on, bool applyOpacity) {
    for (PluginWindowHost* h : hosts_)
        if (h) h->setActive(on, applyOpacity);
}

void PluginWindowsHub::setFrozen(bool on) {
    for (PluginWindowHost* h : hosts_)
        if (h) h->setFrozen(on);
}

QVariantList PluginWindowsHub::opacityEntries() const {
    QVariantList out;
    for (PluginWindowHost* h : hosts_)
        if (h) out += h->opacityEntries();
    return out;
}
