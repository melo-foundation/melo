#include "PluginJsGuard.h"

#include <QJSEngine>
#include <QSet>
#include <QString>
#include <cstdio>

#ifdef MELO_HAVE_QML_PRIVATE
#include <private/qv4engine_p.h>
#endif

namespace {
// GUI thread only, as every QML engine in melo is
QSet<QJSEngine*>& engines() {
    static QSet<QJSEngine*> set;
    return set;
}
}

void meloRegisterPluginEngine(QJSEngine* engine) {
    if (engine) engines().insert(engine);
}

void meloUnregisterPluginEngine(QJSEngine* engine) {
    engines().remove(engine);
}

bool meloPluginJsOnStack() {
#ifdef MELO_HAVE_QML_PRIVATE
    // an engine's current frame is null whenever none of its JS is running
    for (QJSEngine* e : std::as_const(engines()))
        if (e->handle() && e->handle()->currentStackFrame) return true;
#endif
    return false;
}

bool meloPluginMayTrigger(const QString& method) {
    return method == QLatin1String("lyrics/get");
}

bool meloRefusePluginCall(const QString& method) {
    if (!meloPluginJsOnStack() || meloPluginMayTrigger(method)) return false;
    std::fprintf(stderr, "[melo] refusing %s: called from plugin code\n", qPrintable(method));
    return true;
}

bool meloRefuseFromPlugin(const char* what) {
    if (!meloPluginJsOnStack()) return false;
    std::fprintf(stderr, "[melo] refusing %s: called from plugin code\n", what);
    return true;
}
