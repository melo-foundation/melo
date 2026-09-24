#include "WindowController.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QFile>
#include <QFileInfo>
#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QRegion>
#include <QStandardPaths>
#include <cstdio>

// KWin may not answer, and this is the GUI thread. QDBusInterface introspects
// synchronously on construction and its calls wait D-Bus's default 25 s, so a
// wedged compositor would freeze melo. KWinObject sends without introspection
// and bounds every wait.
namespace {

constexpr int kKWinTimeoutMs = 3000;

class KWinObject {
public:
    KWinObject(QString path, QString iface)
        : path_(std::move(path)), iface_(std::move(iface)) {}

    template <typename... Args>
    QDBusMessage call(const QString& method, Args&&... args) const {
        QDBusMessage m = QDBusMessage::createMethodCall(
            QStringLiteral("org.kde.KWin"), path_, iface_, method);
        m.setArguments(QVariantList{arg(std::forward<Args>(args))...});
        return QDBusConnection::sessionBus().call(m, QDBus::Block, kKWinTimeoutMs);
    }

private:
    // A string LITERAL would otherwise become a QVariant holding a const char*,
    // which has no D-Bus type and fails at marshalling rather than at compile
    // time. Every caller passes QString today; this is so that stops being
    // something the next caller has to know.
    static QVariant arg(const char* v) { return QVariant(QString::fromUtf8(v)); }
    template <typename T>
    static QVariant arg(T&& v) { return QVariant::fromValue(std::forward<T>(v)); }

    QString path_;
    QString iface_;
};

}  // namespace

#ifdef MELO_NATIVE_BLUR
#include "WaylandBlur.h"
#elif defined(HAVE_KWINDOWSYSTEM)
#include <KWindowEffects>
#endif

void WindowController::initFocusTracking() {
    appActive_ = QGuiApplication::focusWindow() != nullptr;
    QObject::connect(qGuiApp, &QGuiApplication::focusWindowChanged, this,
                     [this](QWindow* w) {
        const bool a = w != nullptr;
        if (a == appActive_) return;
        appActive_ = a;
        emit appActiveChanged();
    });
}

WindowController::WindowController(QObject* parent) : QObject(parent) {
    initFocusTracking();
    isWayland_ = QGuiApplication::platformName().contains("wayland");
    if (isWayland_) {
        // Ask the bus, not KWin: whether a name is on the bus is a question
        // for the bus daemon, which always answers, so "is KWin here?" cannot
        // hang at startup.
        auto* bus = QDBusConnection::sessionBus().interface();
        kwinAvailable_ = bus && bus->isServiceRegistered(QStringLiteral("org.kde.KWin"));
    }
    if (kwinAvailable_) {
        // Fallback only: KWin folded contrast into the blur effect, so this says
        // no where contrast works; contrastAvailable() asks the protocol first.
        // Never loadEffect("contrast"): it would change every window's drawing
        // for the session, and a melo theme setting is not consent to that.
        const KWinObject fx("/Effects", "org.kde.kwin.Effects");
        QDBusReply<QStringList> effects = fx.call("listOfEffects");
        if (effects.isValid() && effects.value().contains(QStringLiteral("contrast")))
            contrastAvailable_ = true;
    }
    // KWin scripts report geometry to this pid-unique name. Not the MPRIS name,
    // which only the first melo owns: a second instance's geometry would land in
    // the first's saved position. Falls back to the unique ":1.x" name; the
    // well-known one is only for busctl.
    geoService_ = QStringLiteral("com.melo.Geometry.instance%1")
                      .arg(QCoreApplication::applicationPid());
    if (!QDBusConnection::sessionBus().registerService(geoService_))
        geoService_ = QDBusConnection::sessionBus().baseService();
    geoReceiver_ = new GeometryReceiver();
    geoReceiver_->setParent(this);
    QDBusConnection::sessionBus().registerObject(
        QStringLiteral("/melo/geometry"), geoReceiver_,
        QDBusConnection::ExportAllSlots);
    connect(geoReceiver_, &GeometryReceiver::reported,
            this, &WindowController::mainGeometry);
    connect(geoReceiver_, &GeometryReceiver::resizeStarted,
            this, &WindowController::interactiveStarted);
    connect(geoReceiver_, &GeometryReceiver::moveStarted,
            this, &WindowController::interactiveMoveStarted);
    connect(geoReceiver_, &GeometryReceiver::windowReported,
            this, &WindowController::windowGeometry);
}

// KWin's script registry is session-global and keyed by plugin name, not path.
// A script loaded without a name cannot be unloaded, and makes every later
// unnamed loadScript return -1, in every melo. Always load and unload by name.
static QString kwinScriptName(const QString& path) {
    return QFileInfo(path).completeBaseName();
}

// Callers treat false as "KWin is not here", so a refused load is logged
// here or it goes unseen.
static void warnLoadRefused(const QString& name, const QDBusReply<int>& id) {
    std::fprintf(stderr, "[melo] KWin refused to load script '%s' (%s) — window placement and "
                         "the mini/full opacity swap will not run\n",
                 name.toUtf8().constData(),
                 id.isValid() ? "already loaded under this name"
                              : id.error().message().toUtf8().constData());
}

WindowController::~WindowController() {
    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    const auto unload = [&scripting](int id, const QString& path, const QString& name) {
        if (id < 0) return;
        const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(id), "org.kde.kwin.Script");
        runner.call("stop");
        scripting.call("unloadScript", name);
        QFile::remove(path);
    };
    unload(watchScriptId_, watchScriptPath_, watchScriptName_);
    unload(winWatchScriptId_, winWatchScriptPath_, winWatchScriptName_);
    unload(pluginGlueScriptId_, pluginGlueScriptPath_, pluginGlueScriptName_);
    unload(glueScriptId_, glueScriptPath_, glueScriptName_);
}

void WindowController::setInputEnabled(QQuickWindow* win, bool enabled) {
    if (!win) return;
    // Input back is the window's SHAPE (WindowShapeItem keeps it on the
    // window), not the whole rectangle, which a null QRegion is; a region
    // fully off the surface makes every pixel click-through.
    win->setProperty("meloInputOff", !enabled);
    win->setMask(enabled ? win->property("meloShape").value<QRegion>() : QRegion(-100, -100, 1, 1));
}

void WindowController::setInputRegion(QQuickWindow* win, int x, int y, int w, int h) {
    if (!win) return;
    // a region of the caller's own, which a shape change must not replace
    win->setProperty("meloInputOff", true);
    win->setMask(QRegion(x, y, w, h));
}

// A rounded-rect region so the blur follows the window's rounded corners
// instead of frosting the square area behind them. r<=0 -> plain rect.
// Only setBlurRegion calls this, and only on the two paths that have a
// compositor to call — the stub build below has neither.
#if defined(MELO_NATIVE_BLUR) || defined(HAVE_KWINDOWSYSTEM)
static QRegion roundedRegion(int x, int y, int w, int h, int r) {
    if (r <= 0) return QRegion(x, y, w, h);
    r = qMin(r, qMin(w, h) / 2);
    QRegion reg(x + r, y, w - 2 * r, h);          // centre column, full height
    reg += QRegion(x, y + r, w, h - 2 * r);        // full width, centre rows
    // four corner quarter-discs
    reg += QRegion(x, y, 2 * r, 2 * r, QRegion::Ellipse);
    reg += QRegion(x + w - 2 * r, y, 2 * r, 2 * r, QRegion::Ellipse);
    reg += QRegion(x, y + h - 2 * r, 2 * r, 2 * r, QRegion::Ellipse);
    reg += QRegion(x + w - 2 * r, y + h - 2 * r, 2 * r, 2 * r, QRegion::Ellipse);
    return reg;
}
#endif
#ifdef MELO_NATIVE_BLUR
void WindowController::setBlurBehind(QQuickWindow* win, bool on) {
    auto* wb = WaylandBlur::instance();
    if (!wb || !win) return;
    // A null region means the whole surface and follows every resize by itself.
    // A rounded region would need re-cutting on every resize, committed on a
    // frame, to keep blur off 3.4 px² per corner at a 4px radius, which the
    // window paints its own rounded background over anyway. A shaped window is the
    // exception: WindowShapeItem stores its region and re-applies blur on change.
    const QRegion shape = win->property("meloShape").value<QRegion>();
    wb->setBlur(win, on, shape);
}
void WindowController::setBlurRegion(QQuickWindow* win, int x, int y, int w, int h) {
    auto* wb = WaylandBlur::instance();
    if (wb && win) wb->setBlur(win, true, roundedRegion(x, y, w, h, blurRadius_));
}
void WindowController::setBackgroundContrast(QQuickWindow* win, bool on,
                                             double contrast, double saturation) {
    auto* wb = WaylandBlur::instance();
    if (!wb || !win) return;
    // Neutral values send no contrast object: KWin treats its mere existence as
    // an override, so sending 1.0 would replace the user's global blur
    // saturation for melo's window alone.
    const bool neutral = qFuzzyCompare(contrast, 1.0) && qFuzzyCompare(saturation, 1.0);
    wb->setContrast(win, on && !neutral, contrast, 1.0, saturation, QRegion(), QColor());
}
bool WindowController::blurAvailable() const {
    auto* wb = WaylandBlur::instance();
    return wb && wb->available();
}
// The compositor advertised the global and we bound it — there is no better
// evidence than that, and no D-Bus name to go looking for.
bool WindowController::contrastAvailable() const {
    auto* wb = WaylandBlur::instance();
    return (wb && wb->contrastAvailable()) || contrastAvailable_;
}
#elif defined(HAVE_KWINDOWSYSTEM)
void WindowController::setBlurBehind(QQuickWindow* win, bool on) {
    // no region: the whole window, which needs no keeping in sync. See the
    // native path above for why the rounded one is not worth what it costs.
    if (win) KWindowEffects::enableBlurBehind(win, on);
}
void WindowController::setBlurRegion(QQuickWindow* win, int x, int y, int w, int h) {
    if (win) KWindowEffects::enableBlurBehind(win, true,
                 roundedRegion(x, y, w, h, blurRadius_));
}
void WindowController::setBackgroundContrast(QQuickWindow* win, bool on,
                                             double contrast, double saturation) {
    if (win) KWindowEffects::enableBackgroundContrast(win, on, contrast, 1.0, saturation);
}
bool WindowController::blurAvailable() const { return true; }
bool WindowController::contrastAvailable() const { return contrastAvailable_; }
#else
void WindowController::setBlurBehind(QQuickWindow*, bool) {}
void WindowController::setBlurRegion(QQuickWindow*, int, int, int, int) {}
void WindowController::setBackgroundContrast(QQuickWindow*, bool, double, double) {}
bool WindowController::blurAvailable() const { return false; }
bool WindowController::contrastAvailable() const { return false; }
#endif

void WindowController::logLine(const QString& text) {
    std::fprintf(stderr, "%s\n", text.toUtf8().constData());
    std::fflush(stderr);
}

void WindowController::copyToClipboard(const QString& text) {
    if (auto* cb = QGuiApplication::clipboard()) cb->setText(text);
}

// Run a KWin script. Unique path AND unique name per call: KWin keys its
// registry on the NAME (see kwinScriptName), so reusing one is a silent -1.
static bool runKwinScript(const QString& body) {
    static int seq = 0;
    const QString path = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                         + QStringLiteral("/melo-kwin-%1-%2.js")
                               .arg(QCoreApplication::applicationPid()).arg(++seq);
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write(body.toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    const QString name = kwinScriptName(path);
    QDBusReply<int> id = scripting.call("loadScript", path, name);
    const bool ok = id.isValid() && id.value() >= 0;
    if (!ok) warnLoadRefused(name, id);
    if (ok) {
        const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(id.value()), "org.kde.kwin.Script");
        runner.call("run");     // blocking: geometry applied when this returns
        runner.call("stop");
    }
    scripting.call("unloadScript", name);
    QFile::remove(path);
    return ok;
}

static QString findWindowsPrelude() {
    return QStringLiteral(
        "let main = null, mini = null, mq = null;\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %1) continue;\n"
        "  if (w.caption === \"melo\") main = w;\n"
        "  else if (w.caption === \"melo-mini\") mini = w;\n"
        "  else if (w.caption === \"melo-mini-queue\") mq = w;\n"
        "}\n").arg(QCoreApplication::applicationPid());
}

bool WindowController::alignForCollapse(int barHeight) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main && mini) {\n"
        "  const g = main.frameGeometry;\n"
        "  mini.frameGeometry = { x: g.x, y: g.y + g.height - %1, width: g.width, height: %1 };\n"
        "}\n").arg(barHeight));
}

bool WindowController::alignForExpand(int barHeight, int width) {
    if (!kwinAvailable_) return false;
    // Whose width wins: the caller's, since QML may have just set a width
    // the compositor has not seen, and g.width would write the mini bar's
    // width back over it.
    const QString w = width > 0 ? QString::number(width) : QStringLiteral("g.width");
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main && mini) {\n"
        "  const m = mini.frameGeometry;\n"
        "  const g = main.frameGeometry;\n"
        "  main.frameGeometry = { x: m.x, y: m.y + %1 - g.height, width: %2, height: g.height };\n"
        "}\n").arg(QString::number(barHeight), w));
}

// N-window opacity in one script execution. Not findWindowsPrelude(), which
// hardcodes the built-in captions, but its pid guard is kept: instances share
// captions, and one melo would otherwise set another's opacity.
bool WindowController::setWindowOpacities(const QVariantList& windows) {
    if (!kwinAvailable_) return false;
    // caption -> opacity as a JSON object literal (valid JS, and it quotes
    // arbitrary plugin-supplied titles) — see the U+2028 note below for the
    // one thing JSON does NOT do for us.
    QJsonObject want;
    for (const QVariant& v : windows) {
        const QVariantMap m = v.toMap();
        const QString title = m.value(QStringLiteral("title")).toString();
        const QVariant op = m.value(QStringLiteral("opacity"));
        bool numeric = false;
        const double opacity = op.toDouble(&numeric);
        // A malformed entry must NOT fall back to 0: that silently HIDES a
        // window mid-swap, which is the artifact class this whole file exists
        // to prevent. Drop the entry and leave the window's opacity alone.
        if (title.isEmpty() || !numeric) continue;
        want.insert(title, qBound(0.0, opacity, 1.0));
    }
    if (want.isEmpty()) return true;   // nothing asked for; KWin is still there

    QString json = QString::fromUtf8(QJsonDocument(want).toJson(QJsonDocument::Compact));
    // Qt's JSON writer leaves U+2028/U+2029 raw, and they are JS line
    // terminators, so one plugin window title would drop the whole script.
    json.replace(QChar(0x2028), QLatin1String("\\u2028"));
    json.replace(QChar(0x2029), QLatin1String("\\u2029"));

    return runKwinScript(QStringLiteral(
        "const want = %1;\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %2) continue;\n"
        // hasOwnProperty, not `want[caption] !== undefined`: plain member
        // lookup walks the prototype chain, so a window captioned "toString"
        // or "constructor" would be assigned a FUNCTION as its opacity.
        "  if (!Object.prototype.hasOwnProperty.call(want, w.caption)) continue;\n"
        "  w.opacity = want[w.caption];\n"
        "}\n")
        // One two-argument arg(), never a chain: chained arg rescans substituted
        // text, so a "%1" in a title would eat the pid and break the script.
        .arg(json, QString::number(QCoreApplication::applicationPid())));
}

// Move N windows by caption in one script execution; Wayland clients cannot
// position themselves. Caption handling is setWindowOpacities's: JSON literal,
// U+2028/U+2029 escape, own-property lookup, pid guard, single-pass arg().
bool WindowController::moveWindows(const QVariantList& windows) {
    if (!kwinAvailable_) return false;
    QJsonObject want;
    for (const QVariant& v : windows) {
        const QVariantMap m = v.toMap();
        const QString title = m.value(QStringLiteral("title")).toString();
        bool okX = false, okY = false;
        const int x = m.value(QStringLiteral("x")).toInt(&okX);
        const int y = m.value(QStringLiteral("y")).toInt(&okY);
        // A malformed entry must not become {0,0}, which would silently park
        // a window in the screen corner.
        if (title.isEmpty() || !okX || !okY) continue;
        want.insert(title, QJsonObject{{QStringLiteral("x"), qBound(-32000, x, 32000)},
                                       {QStringLiteral("y"), qBound(-32000, y, 32000)}});
    }
    if (want.isEmpty()) return true;

    QString json = QString::fromUtf8(QJsonDocument(want).toJson(QJsonDocument::Compact));
    json.replace(QChar(0x2028), QLatin1String("\\u2028"));
    json.replace(QChar(0x2029), QLatin1String("\\u2029"));

    return runKwinScript(QStringLiteral(
        "const want = %1;\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %2) continue;\n"
        "  if (!Object.prototype.hasOwnProperty.call(want, w.caption)) continue;\n"
        "  const p = want[w.caption];\n"
        "  const g = w.frameGeometry;\n"
        "  w.frameGeometry = { x: p.x, y: p.y, width: g.width, height: g.height };\n"
        "}\n")
        .arg(json, QString::number(QCoreApplication::applicationPid())));
}

bool WindowController::setKeepAbove(bool on) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) main.keepAbove = %1;\n"
        "if (mini) mini.keepAbove = %1;\n").arg(on ? "true" : "false"));
}

bool WindowController::setMiniQueueGlue(bool on) {
    if (!kwinAvailable_) return false;

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    if (!on) {
        if (glueScriptId_ >= 0) {
            const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(glueScriptId_), "org.kde.kwin.Script");
            runner.call("stop");
            scripting.call("unloadScript", glueScriptName_);
            QFile::remove(glueScriptPath_);
            glueScriptId_ = -1;
            glueScriptName_.clear();
        }
        return true;
    }
    if (glueScriptId_ >= 0) return true;   // already glued

    static int seq = 0;
    glueScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                      + QStringLiteral("/melo-kwin-glue-%1-%2.js")
                            .arg(QCoreApplication::applicationPid()).arg(++seq);
    glueScriptName_ = kwinScriptName(glueScriptPath_);
    QFile f(glueScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write((findWindowsPrelude() + QStringLiteral(
        "function glue() {\n"
        "  if (!mini || !main) return;\n"
        "  if (mini.resize) return;   // never reposition per RESIZE frame\n"
        "  const m = mini.frameGeometry;\n"
        "  const g = main.frameGeometry;\n"
        "  const nx = m.x, ny = m.y + m.height - g.height;\n"
        "  if (g.x === nx && g.y === ny) return;   // skip no-op moves\n"
        "  main.frameGeometry = { x: nx, y: ny, width: g.width, height: g.height };\n"
        "}\n"
        "if (mini && main) {\n"
        "  glue();\n"
        "  mini.frameGeometryChanged.connect(glue);\n"
        "  mini.interactiveMoveResizeFinished.connect(glue);   // settle after resize\n"
        "}\n")).toUtf8());
    f.close();

    QDBusReply<int> id = scripting.call("loadScript", glueScriptPath_, glueScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(glueScriptName_, id);
        glueScriptName_.clear();
        return false;
    }
    glueScriptId_ = id.value();
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(glueScriptId_), "org.kde.kwin.Script");
    runner.call("run");   // blocking: initial glue() applied on return; stays loaded
    return true;
}

QString WindowController::pluginWindowGlueScript(const QVariantList& input, qint64 pid) {
    QJsonArray links;
    for (const QVariant& v : input) {
        const QVariantMap m = v.toMap();
        const QString leader = m.value(QStringLiteral("leader")).toString();
        const QString follower = m.value(QStringLiteral("follower")).toString();
        bool dxOk = false, dyOk = false;
        const int dx = m.value(QStringLiteral("dx")).toInt(&dxOk);
        const int dy = m.value(QStringLiteral("dy")).toInt(&dyOk);
        if (leader.isEmpty() || follower.isEmpty() || leader == follower || !dxOk || !dyOk)
            continue;
        links.append(QJsonObject{{QStringLiteral("leader"), leader},
                                 {QStringLiteral("follower"), follower},
                                 {QStringLiteral("dx"), dx},
                                 {QStringLiteral("dy"), dy}});
    }
    if (links.isEmpty()) return {};
    QString json = QString::fromUtf8(QJsonDocument(links).toJson(QJsonDocument::Compact));
    json.replace(QChar(0x2028), QLatin1String("\\u2028"));
    json.replace(QChar(0x2029), QLatin1String("\\u2029"));

    // This is the built-in mini queue's glue generalized to a one-way graph.
    // Only a leader's geometry signal moves its followers. Dragging a follower
    // therefore disconnects it naturally; PluginWindowHost removes that link
    // after its ordinary snap pass observes that it is no longer adjacent.
    return QStringLiteral(
        "const links = %1;\n"
        "const dockWins = Object.create(null);\n"
        "const armed = Object.create(null);\n"
        "const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);\n"
        // Reentrancy guard: links already cover every descendant, but writing a
        // middle leader's geometry fires its frameGeometryChanged synchronously,
        // which would place its followers a second time.
        "let busy = false;\n"
        "const follow = (caption) => {\n"
        "  if (busy) return;\n"
        "  if (!own(dockWins, caption)) return;\n"
        "  const leader = dockWins[caption];\n"
        // Match setMiniQueueGlue: never fight an interactive resize. The host
        // re-seats size-dependent edges after the resize settles.
        "  if (leader.resize) return;\n"
        "  busy = true;\n"
        "  const g = leader.frameGeometry;\n"
        "  for (const link of links) {\n"
        "    if (link.leader !== caption || !own(dockWins, link.follower)) continue;\n"
        "    const follower = dockWins[link.follower];\n"
        "    const f = follower.frameGeometry;\n"
        "    const nx = g.x + link.dx, ny = g.y + link.dy;\n"
        "    if (f.x === nx && f.y === ny) continue;\n"
        "    follower.frameGeometry = { x: nx, y: ny, width: f.width, height: f.height };\n"
        "  }\n"
        "  busy = false;\n"
        "};\n"
        "const arm = (w) => {\n"
        "  if (w.pid !== %2) return;\n"
        "  let relevant = false, leads = false;\n"
        "  for (const link of links) {\n"
        "    if (link.leader === w.caption) { relevant = true; leads = true; }\n"
        "    if (link.follower === w.caption) relevant = true;\n"
        "  }\n"
        "  if (!relevant) return;\n"
        "  dockWins[w.caption] = w;\n"
        "  if (leads && !own(armed, w.caption)) {\n"
        "    armed[w.caption] = true;\n"
        "    w.frameGeometryChanged.connect(() => follow(w.caption));\n"
        "    w.interactiveMoveResizeFinished.connect(() => follow(w.caption));\n"
        "  }\n"
        // A follower can map after its leader on Wayland. Re-run the affected
        // leader as each surface arrives so initial seating does not race map.
        "  for (const link of links)\n"
        "    if (link.leader === w.caption || link.follower === w.caption) follow(link.leader);\n"
        "};\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(json, QString::number(pid));
}

void WindowController::unloadPluginWindowGlue() {
    if (pluginGlueScriptId_ < 0) return;
    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(pluginGlueScriptId_), "org.kde.kwin.Script");
    runner.call("stop");
    scripting.call("unloadScript", pluginGlueScriptName_);
    QFile::remove(pluginGlueScriptPath_);
    pluginGlueScriptId_ = -1;
    pluginGlueScriptPath_.clear();
    pluginGlueScriptName_.clear();
    pluginGlueBody_.clear();
}

bool WindowController::setPluginWindowGlue(const QVariantList& links) {
    if (!kwinAvailable_) return false;
    const QString body = pluginWindowGlueScript(links, QCoreApplication::applicationPid());
    if (pluginGlueScriptId_ >= 0 && body == pluginGlueBody_) return true;
    unloadPluginWindowGlue();
    if (body.isEmpty()) return true;

    static int seq = 0;
    pluginGlueScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                            + QStringLiteral("/melo-kwin-pluginglue-%1-%2.js")
                                  .arg(QCoreApplication::applicationPid()).arg(++seq);
    pluginGlueScriptName_ = kwinScriptName(pluginGlueScriptPath_);
    QFile f(pluginGlueScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        pluginGlueScriptPath_.clear();
        pluginGlueScriptName_.clear();
        return false;
    }
    f.write(body.toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    QDBusReply<int> id = scripting.call("loadScript", pluginGlueScriptPath_,
                                        pluginGlueScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(pluginGlueScriptName_, id);
        QFile::remove(pluginGlueScriptPath_);
        pluginGlueScriptPath_.clear();
        pluginGlueScriptName_.clear();
        return false;
    }
    pluginGlueScriptId_ = id.value();
    pluginGlueBody_ = body;
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(pluginGlueScriptId_), "org.kde.kwin.Script");
    runner.call("run");
    return true;
}

// Persistent watcher: reports the main window's frame once now and then
// after every completed user move/resize. No polling; programmatic moves
// (applyMainPosition) don't fire it, so restore can't echo back.
void WindowController::watchMainGeometry() {
    if (!kwinAvailable_ || watchScriptId_ >= 0) return;
    // No destination = a watcher that reports into the void. Refuse rather than
    // fall back to a name another instance may own.
    if (geoService_.isEmpty()) return;

    static int seq = 0;
    watchScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                       + QStringLiteral("/melo-kwin-watch-%1-%2.js")
                             .arg(QCoreApplication::applicationPid()).arg(++seq);
    watchScriptName_ = kwinScriptName(watchScriptPath_);
    QFile f(watchScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    // %1 is geoService_, substituted before the prelude is prepended so arg()
    // never rescans the prelude's pid. Armed by windowAdded as well as the walk:
    // on Wayland melo's window often is not in windowList() yet at startup.
    f.write((QStringLiteral(
        "let main = null, mini = null;\n"
        "const report = () => {\n"
        "  if (!main) return;\n"
        "  const g = main.frameGeometry;\n"
        "  const c = workspace.cursorPos;\n"
        "  const inR = (r) => c.x >= r.x && c.x <= r.x + r.width\n"
        "                  && c.y >= r.y && c.y <= r.y + r.height;\n"
        "  const inside = inR(g) || (mini && inR(mini.frameGeometry)) ? 1 : 0;\n"
        "  callDBus(\"%2\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"Report\",\n"
        "           g.x + \",\" + g.y + \",\" + g.width + \",\" + g.height + \",\" + inside);\n"
        "};\n"
        "const started = (w) => {\n"
        // Which one it is: KWin sets `resize` on the window for the length
        // of an interactive RESIZE and leaves it false for a move, which
        // setMiniQueueGlue's script relies on too.
        "  callDBus(\"%2\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"Report\",\n"
        "           (w && w.resize) ? \"start\" : \"startMove\");\n"
        "};\n"
        "const arm = (w) => {\n"
        "  if (w.pid !== %1) return;\n"
        "  if (w.caption === \"melo\") main = w;\n"
        // mini-bar drags end the same way (drag-hold release in QML)
        "  else if (w.caption === \"melo-mini\") mini = w;\n"
        "  else return;\n"
        "  w.interactiveMoveResizeFinished.connect(report);\n"
        // The handler is shared by melo and the compact bar, so it is told
        // WHICH window raised it rather than assuming main.
        "  w.interactiveMoveResizeStarted.connect(() => started(w));\n"
        "  report();\n"
        "};\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(QString::number(QCoreApplication::applicationPid()), geoService_)).toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    QDBusReply<int> id = scripting.call("loadScript", watchScriptPath_, watchScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(watchScriptName_, id);
        watchScriptName_.clear();
        return;
    }
    watchScriptId_ = id.value();
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(watchScriptId_), "org.kde.kwin.Script");
    runner.call("run");   // stays loaded for the app's lifetime
}

// The watcher's report(), fired once on demand. Separate from
// watchMainGeometry(), which early-returns once installed and then reports only
// after an interactive move.
bool WindowController::reportMainGeometry() {
    if (!kwinAvailable_ || geoService_.isEmpty()) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) {\n"
        "  const g = main.frameGeometry;\n"
        "  const c = workspace.cursorPos;\n"
        "  const inR = (r) => c.x >= r.x && c.x <= r.x + r.width\n"
        "                  && c.y >= r.y && c.y <= r.y + r.height;\n"
        "  const inside = inR(g) || (mini && inR(mini.frameGeometry)) ? 1 : 0;\n"
        "  callDBus(\"%1\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"Report\",\n"
        "           g.x + \",\" + g.y + \",\" + g.width + \",\" + g.height + \",\" + inside);\n"
        "}\n").arg(geoService_));
}

// The per-window watcher's body. Caption handling is setWindowOpacities's: JSON
// literal, U+2028/U+2029 escape, own-property lookup, pid guard, single-pass
// arg(). Also armed by windowAdded: on Wayland a just-mapped window may not be
// in windowList() yet.
QString WindowController::windowGeometryScript(const QStringList& captions,
                                               qint64 pid, const QString& service) {
    QJsonObject want;
    for (const QString& c : captions) if (!c.isEmpty()) want.insert(c, 1);
    QString json = QString::fromUtf8(QJsonDocument(want).toJson(QJsonDocument::Compact));
    json.replace(QChar(0x2028), QLatin1String("\\u2028"));
    json.replace(QChar(0x2029), QLatin1String("\\u2029"));

    return QStringLiteral(
        "const want = %1;\n"
        // ONE STRING, never five arguments: callDBus marshals a JS number as a
        // DBus double, which silently fails to match an int slot (the note
        // above GeometryReceiver in WindowController.h). The caption goes FIRST and ReportWindow takes
        // the last four fields as the numbers, so a comma in it survives.
        "const report = (w) => {\n"
        "  const g = w.frameGeometry;\n"
        "  callDBus(\"%3\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"ReportWindow\",\n"
        "           w.caption + \",\" + g.x + \",\" + g.y + \",\"\n"
        "                     + g.width + \",\" + g.height);\n"
        "};\n"
        "const arm = (w) => {\n"
        "  if (w.pid !== %2) return;\n"
        "  if (!Object.prototype.hasOwnProperty.call(want, w.caption)) return;\n"
        "  w.interactiveMoveResizeFinished.connect(() => report(w));\n"
        // Once now, so the host learns where the compositor actually put a
        // window rather than only where melo asked for it to go. The host
        // treats a window's FIRST report as adoption, not as a drag.
        "  report(w);\n"
        "};\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(json, QString::number(pid), service);
}

void WindowController::unloadWindowWatcher() {
    if (winWatchScriptId_ < 0) return;
    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(winWatchScriptId_), "org.kde.kwin.Script");
    runner.call("stop");
    // BY NAME, never by path — see kwinScriptName(): unloadScript(path) matches
    // nothing, the script stays loaded forever, and every later loadScript in
    // this session returns -1.
    scripting.call("unloadScript", winWatchScriptName_);
    QFile::remove(winWatchScriptPath_);
    winWatchScriptId_ = -1;
    winWatchScriptName_.clear();
    winWatchScriptPath_.clear();
    winWatchBody_.clear();
}

bool WindowController::setPluginWindowsAlwaysUp(const QStringList& captions, bool on) {
    if (!kwinAvailable_) return false;
    QStringList wanted = captions;
    wanted.removeAll(QString());

    QString body;
    if (on && !wanted.isEmpty()) {
        QStringList quoted;
        for (const QString& c : wanted)
            quoted << QStringLiteral("\"%1\"").arg(QString(c).replace(u'"', QStringLiteral("\\\"")));
        body = QStringLiteral(
            "const pid = %1;\n"
            "const caps = [%2];\n"
            "const hold = (w) => {\n"
            "  if (w.pid !== pid || caps.indexOf(w.caption) < 0) return;\n"
            "  w.keepAbove = true;\n"
            // Decline the minimize, rather than un-minimize afterwards: KWin
            // raises minimizedChanged after it has applied the state, so this
            // is one frame of gone-and-back at worst and nothing at best.
            "  w.minimizedChanged.connect(() => { if (w.minimized) w.minimized = false; });\n"
            "  if (w.minimized) w.minimized = false;\n"
            "};\n"
            "for (const w of workspace.windowList()) hold(w);\n"
            // A window that appears later is the ordinary case: the user turns
            // the setting on, then opens the playlist.
            "workspace.windowAdded.connect(hold);\n")
            .arg(QString::number(QCoreApplication::applicationPid()), quoted.join(u','));
    }
    if (alwaysUpScriptId_ >= 0 && body == alwaysUpBody_) return true;

    if (alwaysUpScriptId_ >= 0) {
        const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
        const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(alwaysUpScriptId_), "org.kde.kwin.Script");
        runner.call("stop");
        scripting.call("unloadScript", alwaysUpScriptName_);   // by NAME; see kwinScriptName()
        QFile::remove(alwaysUpScriptPath_);
        alwaysUpScriptId_ = -1;
        alwaysUpScriptName_.clear();
        alwaysUpScriptPath_.clear();
        alwaysUpBody_.clear();
        // Unloading stops the handler but leaves keepAbove where it was, so
        // put it back rather than leaving the windows pinned forever.
        if (!wanted.isEmpty()) {
            QStringList clear;
            for (const QString& c : wanted)
                clear << QStringLiteral("\"%1\"").arg(QString(c).replace(u'"', QStringLiteral("\\\"")));
            runKwinScript(QStringLiteral(
                "const caps = [%1];\n"
                "for (const w of workspace.windowList())\n"
                "  if (w.pid === %2 && caps.indexOf(w.caption) >= 0) w.keepAbove = false;\n")
                .arg(clear.join(u','), QString::number(QCoreApplication::applicationPid())));
        }
    }
    if (body.isEmpty()) return true;    // "hold nothing" is the uninstall above

    static int seq = 0;
    alwaysUpScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                          + QStringLiteral("/melo-kwin-alwaysup-%1-%2.js")
                                .arg(QCoreApplication::applicationPid()).arg(++seq);
    alwaysUpScriptName_ = kwinScriptName(alwaysUpScriptPath_);
    QFile f(alwaysUpScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        alwaysUpScriptName_.clear();
        alwaysUpScriptPath_.clear();
        return false;
    }
    f.write(body.toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    QDBusReply<int> id = scripting.call("loadScript", alwaysUpScriptPath_, alwaysUpScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(alwaysUpScriptName_, id);
        QFile::remove(alwaysUpScriptPath_);
        alwaysUpScriptName_.clear();
        alwaysUpScriptPath_.clear();
        return false;
    }
    alwaysUpScriptId_ = id.value();
    alwaysUpBody_ = body;
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(alwaysUpScriptId_), "org.kde.kwin.Script");
    runner.call("run");
    return true;
}

bool WindowController::watchWindowGeometry(const QStringList& captions) {
    if (!kwinAvailable_) return false;
    const QString body = windowGeometryScript(captions, QCoreApplication::applicationPid(),
                                              geoService_);
    if (winWatchScriptId_ >= 0 && body == winWatchBody_) return true;   // same set already watched
    unloadWindowWatcher();
    QStringList wanted = captions;
    wanted.removeAll(QString());
    if (wanted.isEmpty()) return true;      // "watch nothing" is the uninstall above
    // No destination = a watcher that reports into the void.
    if (geoService_.isEmpty()) return false;

    static int seq = 0;
    winWatchScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                          + QStringLiteral("/melo-kwin-watchwin-%1-%2.js")
                                .arg(QCoreApplication::applicationPid()).arg(++seq);
    winWatchScriptName_ = kwinScriptName(winWatchScriptPath_);
    QFile f(winWatchScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        winWatchScriptName_.clear();
        winWatchScriptPath_.clear();
        return false;
    }
    f.write(body.toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    QDBusReply<int> id = scripting.call("loadScript", winWatchScriptPath_, winWatchScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(winWatchScriptName_, id);
        QFile::remove(winWatchScriptPath_);
        winWatchScriptName_.clear();
        winWatchScriptPath_.clear();
        return false;
    }
    winWatchScriptId_ = id.value();
    winWatchBody_ = body;
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(winWatchScriptId_), "org.kde.kwin.Script");
    runner.call("run");   // stays loaded until the set changes or the host goes away
    return true;
}

bool WindowController::applyMainPosition(int x, int y) {
    if (!kwinAvailable_) return false;
    // A saved position can land off the current screen: a different display
    // scale, a monitor unplugged, or the window parked at an edge. KWin
    // places it there without complaint and the window then sits in the
    // taskbar drawing nothing. Clamp into the work area before applying.
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) {\n"
        "  const g = main.frameGeometry;\n"
        "  let a = null;\n"
        "  try { a = workspace.clientArea(KWin.MaximizeArea, main); } catch (e) { a = null; }\n"
        "  if (!a && main.output) a = main.output.geometry;\n"
        "  let nx = %1, ny = %2;\n"
        "  if (a && a.width > 0 && a.height > 0) {\n"
        "    nx = Math.max(a.x, Math.min(nx, a.x + a.width - g.width));\n"
        "    ny = Math.max(a.y, Math.min(ny, a.y + a.height - g.height));\n"
        "  }\n"
        "  main.frameGeometry = { x: nx, y: ny, width: g.width, height: g.height };\n"
        "}\n").arg(x).arg(y));
}

bool WindowController::applyMainGeometry(int x, int y, int w, int h) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) main.frameGeometry = { x: %1, y: %2, width: %3, height: %4 };\n")
        .arg(x).arg(y).arg(w).arg(h));
}
