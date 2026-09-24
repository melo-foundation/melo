#pragma once
#include <QList>
#include <QObject>
#include <QVariantList>

class PluginWindowHost;

// One `PluginWindows` for every plugin that owns windows, so Main.qml swaps
// melo, melo-mini and all plugin windows in one KWin script call; a second
// call would show a 1-frame gap or double.
// Does not own the hosts: main.cpp holds them in unique_ptrs and destroys them
// before this hub is cleared or reset.
class PluginWindowsHub : public QObject {
    Q_OBJECT
public:
    explicit PluginWindowsHub(QObject* parent = nullptr);

    void add(PluginWindowHost* host);   // does not take ownership
    void clear();
    bool isEmpty() const;

    Q_INVOKABLE void setActive(bool on, bool applyOpacity = true);
    // Hold every plugin's content still; see PluginWindowHost::setFrozen.
    Q_INVOKABLE void setFrozen(bool on);
    // Concatenated, never merged: each host reports its own windows by caption
    // and no two plugins share one.
    Q_INVOKABLE QVariantList opacityEntries() const;

private:
    QList<PluginWindowHost*> hosts_;
};
