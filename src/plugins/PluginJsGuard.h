#pragma once

class QJSEngine;
class QString;

// Plugin QML can reach melo's own QML objects (a slot occupant's `parent`
// chain, Window.window) and call their functions, which run in melo's engine.
// So melo's QML-facing C++ (sidecar.rpc, Settings, Library, ThemeBackend,
// Portal, Updater, NodeSetup, WindowCtl.showFile) refuses while any plugin
// engine has JS on the stack: a call chain that starts in plugin code reaches
// the sidecar or the disk only through the MeloUi bridge. Player, Queue and
// Suggestions are the bridge's own targets and are not guarded.
void meloRegisterPluginEngine(QJSEngine* engine);
void meloUnregisterPluginEngine(QJSEngine* engine);

// True while plugin JS is running, however it reached the caller. False when
// built without Qt's QML private headers (MELO_HAVE_QML_PRIVATE unset).
bool meloPluginJsOnStack();

// The one sidecar method melo's QML calls synchronously when a plugin skips a
// track through the bridge: lyrics/get (NowPlaying's onVidChanged).
bool meloPluginMayTrigger(const QString& method);

// What SidecarService's QML entry points ask: true (and a log line) when the
// call is refused.
bool meloRefusePluginCall(const QString& method);

// What a QML-facing store's writer asks: true (and a log line) when plugin JS
// is on the stack. `what` names the call in the log.
bool meloRefuseFromPlugin(const char* what);
