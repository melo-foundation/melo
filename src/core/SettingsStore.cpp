#include <QJsonArray>
#include "SettingsStore.h"
#include "paths.h"
#include "jsvalue.h"
#include "SidecarService.h"
#include "RpcClient.h"

#include <QDir>
#include <QJSValue>
#include <QJsonValue>

// unwrapJs lives in jsvalue.h — see the trap it exists for.

SettingsStore::SettingsStore(SidecarService* sidecar, QObject* parent)
    : QObject(parent), sidecar_(sidecar) {
    connect(sidecar_, &SidecarService::readyChanged, this, [this] {
        if (sidecar_->ready()) refresh();
    });
}

QString SettingsStore::dataDir() const {
    return meloConfigDir();   // shared source of truth (src/core/paths.h)
}

void SettingsStore::refresh() {
    auto* c = sidecar_->call("settings/get");
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) { apply(r.toObject()); });
}

void SettingsStore::patch(const QJsonObject& p, const QStringList& holdUi, const QStringList& removeUi) {
    // optimistic local apply, authoritative on reply
    for (auto it = p.begin(); it != p.end(); ++it) s_[it.key()] = it.value();
    // Held until this write's own reply. Any reply (this one's, another
    // patch's, a refresh) replaces the mirror wholesale with a snapshot the
    // sidecar may have taken before this write reached it, so the keys written
    // here go back on top of every snapshot until then.
    const QJsonObject ui = s_["ui"].toObject();
    const quint64 n = ++writeSeq_;
    for (const QString& k : holdUi) { pendingUi_[k] = ui.value(k); pendingSeq_[k] = n; }
    emit changed();
    // The sidecar merges ui per key, so a key left out of the patch stays:
    // a removal is named to it, or it comes back with the next snapshot
    auto* c = sidecar_->call("settings/set", {{"patch", p}, {"removeUi", QJsonArray::fromStringList(removeUi)}});
    connect(c, &RpcCall::finished, this, [this, holdUi, n](const QJsonValue& r) {
        // Only this write's own keys, and only if nothing newer has claimed
        // them since: a reply releasing a key a later write is still holding
        // lets that reply's older snapshot replace the newer value.
        for (const QString& k : holdUi)
            if (pendingSeq_.value(k) == n) { pendingUi_.remove(k); pendingSeq_.remove(k); }
        apply(r.toObject());
    });
}

void SettingsStore::apply(const QJsonObject& fresh) {
    s_ = fresh;
    if (!pendingUi_.isEmpty()) {
        QJsonObject ui = s_["ui"].toObject();
        // a held removal is Undefined: assigning that through operator[]
        // leaves a null behind, so it is removed by name
        for (auto it = pendingUi_.begin(); it != pendingUi_.end(); ++it) {
            if (it.value().isUndefined()) ui.remove(it.key()); else ui[it.key()] = it.value();
        }
        s_["ui"] = ui;
    }
    if (!loaded_) { loaded_ = true; emit loadedChanged(); }
    emit changed();
}

QVariant SettingsStore::uiGet(const QString& key, const QVariant& fallback) const {
    const QJsonObject ui = s_["ui"].toObject();
    return ui.contains(key) ? ui[key].toVariant() : fallback;
}

void SettingsStore::uiSet(const QString& key, const QVariant& value) {
    QJsonObject ui = s_["ui"].toObject();
    ui[key] = QJsonValue::fromVariant(unwrapJs(value));
    patch({{"ui", ui}}, {key});
}

void SettingsStore::uiSetMany(const QVariantMap& values) {
    QJsonObject ui = s_["ui"].toObject();
    for (auto it = values.begin(); it != values.end(); ++it)
        ui[it.key()] = QJsonValue::fromVariant(unwrapJs(it.value()));
    patch({{"ui", ui}}, QStringList(values.keys()));
}

// Set + REMOVE in one RPC patch: theme switches adopt the new theme's
// appearance wholesale, clearing overrides the theme doesn't define.
void SettingsStore::uiApply(const QVariantMap& values, const QStringList& remove) {
    QJsonObject ui = s_["ui"].toObject();
    for (auto it = values.begin(); it != values.end(); ++it)
        ui[it.key()] = QJsonValue::fromVariant(unwrapJs(it.value()));
    for (const QString& key : remove) ui.remove(key);
    // A removed key is held as a removal too: without it a stale snapshot
    // brings back the override a theme switch (or a section's Theme) has
    // just cleared. patch() holds ui.value(k), which for a removed key
    // is Undefined, and inserting Undefined into the mirror removes it.
    QStringList hold = QStringList(values.keys());
    hold += remove;
    patch({{"ui", ui}}, hold, remove);
}

bool SettingsStore::uiHas(const QString& key) const {
    return s_["ui"].toObject().contains(key);
}
