#include <QJsonArray>
#include "SettingsStore.h"
#include "paths.h"
#include "LogTail.h"
#include "LogFile.h"
#include "jsvalue.h"
#include "SidecarService.h"
#include "RpcClient.h"
#include "../plugins/PluginJsGuard.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QSysInfo>
#include <QUrl>
#include <cstdio>
#include <QJsonDocument>
#include <QJSValue>
#include <QRegularExpression>
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

QVariantMap SettingsStore::writeReport(const QString& kind, const QVariantMap& details) const {
    if (meloRefuseFromPlugin("Settings.writeReport")) return {};
    const QDir dir(dataDir() + QStringLiteral("/reports"));
    if (!dir.mkpath(QStringLiteral("."))) return {};
    QString safe = kind;
    safe.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9_-]")), QStringLiteral("_"));
    const QString path = dir.filePath(QStringLiteral("%1-%2.txt").arg(safe.isEmpty() ? QStringLiteral("error") : safe,
        QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss"))));
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return {};
    QString out = QStringLiteral("melo %1, Qt %2, %3\nkind: %4\nwritten: %5\n")
        .arg(QCoreApplication::applicationVersion(), QString::fromLatin1(qVersion()),
             QSysInfo::prettyProductName(), kind,
             QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
    for (auto it = details.cbegin(); it != details.cend(); ++it) {
        const QVariant v = it.value();
        const QString text = (v.typeId() == QMetaType::QVariantMap || v.typeId() == QMetaType::QVariantList)
            ? QString::fromUtf8(QJsonDocument::fromVariant(v).toJson(QJsonDocument::Compact)) : v.toString();
        // the log's rules: a detail can carry a cookie or a stream URL
        out += QString::fromUtf8(LogFile::redact(QStringLiteral("%1: %2").arg(it.key(), text).toUtf8())) + QLatin1Char('\n');
    }
    const QStringList tail = meloLogTail(dataDir() + QStringLiteral("/logs"), 500);
    if (!tail.isEmpty()) out += QStringLiteral("\n--- last %1 lines of melo.log ---\n%2\n").arg(tail.size()).arg(tail.join(QLatin1Char('\n')));
    f.write(out.toUtf8());
    f.close();
    writeReportReadme(dir);
    std::fprintf(stderr, "[melo] %s report written to %s\n", kind.toUtf8().constData(), path.toUtf8().constData());
    return {{"path", path}, {"folder", QUrl::fromLocalFile(dir.absolutePath()).toString()},
            {"version", QCoreApplication::applicationVersion()}, {"system", QSysInfo::prettyProductName()}};
}

const char* const SettingsStore::kReportIssueUrl =
    "https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml";

// README.txt beside the reports, rewritten with each one
void SettingsStore::writeReportReadme(const QDir& dir) {
    QFile f(dir.filePath(QStringLiteral("README.txt")));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return;
    f.write(QStringLiteral(
        "Reporting a problem in melo\n"
        "\n"
        "1. Open the bug form: %1\n"
        "2. Fill in \"Steps to reproduce\".\n"
        "3. Drag the newest .txt file from this folder into the \"Report file\" box.\n"
        "\n"
        "No GitHub account: post the file in melo's Discord instead: %2\n"
        "\n"
        "Cookies, passwords and tokens are removed from these files.\n"
        "They can still name tracks and folders: delete anything you want to keep private.\n")
        .arg(QString::fromLatin1(kReportIssueUrl), QStringLiteral("https://discord.gg/T2jHMX6AcG")).toUtf8());
}

bool SettingsStore::loadLocal() {
    QFile f(dataDir() + QStringLiteral("/settings.v2.json"));
    if (!f.open(QIODevice::ReadOnly)) return false;
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return false;
    apply(doc.object());
    return true;
}

void SettingsStore::refresh() {
    auto* c = sidecar_->call("settings/get");
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) { apply(r.toObject()); });
}

void SettingsStore::patch(const QJsonObject& p, const QStringList& holdUi, const QStringList& removeUi) {
    // every setter and uiSet lands here
    if (meloRefuseFromPlugin("a Settings write")) return;
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
    // a refused write (a profile name the sidecar rejects): the mirror goes back to what is saved
    connect(c, &RpcCall::failed, this, [this, holdUi, n](int, const QString&) {
        for (const QString& k : holdUi)
            if (pendingSeq_.value(k) == n) { pendingUi_.remove(k); pendingSeq_.remove(k); }
        refresh();
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
