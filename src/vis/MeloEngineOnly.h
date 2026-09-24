#pragma once
#include <QQmlEngine>
#include <QQuickItem>
#include <cstdio>

// The `Melo 1.0` types belong to melo's QML only. qmlRegisterType writes a
// process-global registry, so `import Melo 1.0` resolves inside a plugin's
// engine whatever its import path; a type that exposes anything sensitive
// compares qmlEngine(this) with the main engine and refuses itself.
//
// `Visualizer` renders the process-global PCM queue (VisualizerItem::s_pcm), so
// in a plugin it would render live audio with no grant, bypassing the
// owner-keyed FFT arbiter.
//
// Checked at componentComplete: qmlEngine(this) is null during construction.
inline QQmlEngine*& meloOwnEngine() {
    static QQmlEngine* e = nullptr;
    return e;
}

// True when this item may run. A false answer has already complained.
inline bool meloEngineOwns(QQuickItem* item, const char* typeName) {
    QQmlEngine* mine = qmlEngine(item);
    if (!mine || !meloOwnEngine() || mine == meloOwnEngine()) return true;
    std::fprintf(stderr,
                 "[melo] refusing Melo.%s: `import Melo 1.0` is melo's own QML, "
                 "not a plugin's — the type registry is process-global and the "
                 "plugin import path does not gate it\n", typeName);
    item->setVisible(false);
    item->setEnabled(false);
    return false;
}
