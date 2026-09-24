#pragma once
#include <QString>
#include <QDir>

// melo's config/data directory: the sidecar's "dataDir" (SidecarService::initialize),
// SettingsStore::dataDir(), and the root of plugins/ and plugin-data/. Do not
// re-derive the path. MELO_CONFIG_DIR lets a test instance run beside a live melo
// without racing its settings, library and cookie files.
inline QString meloConfigDir() {
    const QByteArray env = qgetenv("MELO_CONFIG_DIR");
    if (!env.isEmpty()) return QString::fromLocal8Bit(env);
    return QDir::homePath() + "/.config/melo";
}
