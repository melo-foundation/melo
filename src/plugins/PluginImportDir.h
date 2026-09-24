#pragma once
#include <QString>
#include <QFileInfo>
#include <QCoreApplication>

// The only import path a plugin QML engine is given. Resolution order, as for
// the main QML dir in main.cpp: env override, beside the executable, then the
// dev tree path compiled in. Callers must treat an empty return as fatal.
//
// A packaged build must not fall back to MELO_DEV_PLUGIN_IMPORT_DIR: it is the
// build machine's path and would give plugins the full system import set.
//
// MELO_PLUGIN_IMPORT_DIR defeats containment on purpose, for working on plugin
// UI against a hand-edited import set. Aimed at the system QML dir it restores
// Qt.labs.platform, QtQuick.Dialogs and LocalStorage, and the qmldir probe
// passes. Accepted: the threat model is a hostile plugin, and whoever can set
// this variable can already replace the binary (same as MELO_QML_DIR).
//
// A static Qt has no module directory to curate: modules are compiled in and
// registered under :/qt-project.org/imports, and a qmldir beside them names a .a
// nothing can dlopen. There the resource root is the curated set, because Qt's
// finalization links a static plugin only for imports melo's own QML uses
// (QtQuick, QtQml, Effects, Shapes, Window); LocalStorage, Controls and Qt.labs.*
// are not in the binary. This holds only while melo's own QML imports nothing
// dangerous; if melo ever imports QtQuick.Dialogs, plugins get it too and the
// resource tree must be curated at build time.
#ifdef MELO_QT_STATIC
inline QString meloPluginImportDir() {
    return QStringLiteral(":/qt-project.org/imports");
}
#else
inline QString meloPluginImportDir() {
    const QString env = qEnvironmentVariable("MELO_PLUGIN_IMPORT_DIR");
    if (!env.isEmpty() && QFileInfo::exists(env + "/QtQuick/qmldir")) return env;
    const QString local = QCoreApplication::applicationDirPath() + "/plugin-qml-imports";
    if (QFileInfo::exists(local + "/QtQuick/qmldir")) return local;
    const QString dev = QStringLiteral(MELO_DEV_PLUGIN_IMPORT_DIR);
    if (QFileInfo::exists(dev + "/QtQuick/qmldir")) return dev;
    return QString();
}
#endif
