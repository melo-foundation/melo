#include "WindowController.h"
#include "../plugins/PluginJsGuard.h"
#include "PinMode.h"
#include "WindowMask.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDBusPendingCallWatcher>
#include <QDesktopServices>
#include <QUrl>
#include <QFile>
#include <QFileInfo>
#include <QClipboard>
#include <QCursor>
#include <QMouseEvent>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QOpenGLContext>
#include <memory>
#include <QRegion>
#include <QScreen>
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
    // A string literal would otherwise become a QVariant holding a const char*,
    // which has no D-Bus type and fails at marshalling, not at compile time.
    static QVariant arg(const char* v) { return QVariant(QString::fromUtf8(v)); }
    template <typename T>
    static QVariant arg(T&& v) { return QVariant::fromValue(std::forward<T>(v)); }

    QString path_;
    QString iface_;
};

}  // namespace

#ifdef MELO_NATIVE_BLUR
#include "WaylandBlur.h"
#include <qpa/qplatformnativeinterface.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#elif defined(HAVE_KWINDOWSYSTEM)
#include <KWindowEffects>
#endif
#ifdef MELO_X11
#include "X11Effects.h"
#endif
// melo's own blur: Wayland protocols and/or the X11 property. KF6 covers both
// where it is the fallback, so the X11 path alone does not replace it.
#if defined(MELO_NATIVE_BLUR) || (defined(MELO_X11) && !defined(HAVE_KWINDOWSYSTEM))
#define MELO_OWN_BLUR 1
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
    isX11_ = QGuiApplication::platformName() == QLatin1String("xcb");
#ifdef MELO_X11
    if (isX11_ && qEnvironmentVariableIsSet("MELO_GEOM_DEBUG")) x11InstallSyncTrace();
#endif
    if (isWayland_ || isX11_) {
        // Ask the bus, not KWin: whether a name is on the bus is a question
        // for the bus daemon, which always answers, so "is KWin here?" cannot
        // hang at startup.
        auto* bus = QDBusConnection::sessionBus().interface();
        const bool onBus = bus && bus->isServiceRegistered(QStringLiteral("org.kde.KWin"));
        const QString session = qEnvironmentVariable("KDE_SESSION_VERSION");
        bool known = false;
        session.trimmed().toInt(&known);
        // no session version: KWin's own, bounded so a busy KWin cannot stall startup
        QString info;
        if (onBus && !known) {
            const auto msg = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"),
                QStringLiteral("/KWin"), QStringLiteral("org.kde.KWin"), QStringLiteral("supportInformation"));
            const QDBusReply<QString> r = QDBusConnection::sessionBus().call(msg, QDBus::Block, 500);
            if (r.isValid()) info = r.value();
        }
        kwinAvailable_ = kwinScriptingFor(QGuiApplication::platformName(), onBus, session, info);
    }
    canPlaceWindows_ = kwinAvailable_ && qEnvironmentVariable("MELO_NO_PLACEMENT") != QLatin1String("1");
    pinMode_ = pinModeFor(QGuiApplication::platformName(),
                          qEnvironmentVariable("XDG_CURRENT_DESKTOP"), kwinAvailable_,
                          qEnvironmentVariable("MELO_PIN_MODE"));
#ifndef MELO_NATIVE_BLUR
    // built without the QtGui private headers: no xdg_toplevel to send it on
    if (pinMode_ == QLatin1String("menu")) pinMode_ = QStringLiteral("none");
#endif
    std::fprintf(stderr, "[melo] platform: %s, pin: %s, placement: %s\n",
                 qPrintable(QGuiApplication::platformName()), qPrintable(pinMode_),
                 canPlaceWindows_ ? "yes" : "no");
#ifdef MELO_NATIVE_BLUR
    if (auto* wb = WaylandBlur::instance()) {
        lastBlur_ = wb->available();
        lastContrast_ = contrastAvailable();
        connect(wb, &WaylandBlur::availabilityChanged, this, [this] {
            const bool b = blurAvailable(), c = contrastAvailable();
            if (b != lastBlur_) { lastBlur_ = b; emit blurAvailableChanged(); }
            if (c != lastContrast_) { lastContrast_ = c; emit contrastAvailableChanged(); }
        });
    }
#endif
#if defined(MELO_X11) && defined(MELO_OWN_BLUR)
    if (auto* xb = X11Blur::instance()) {
        lastBlur_ = xb->available();
        connect(xb, &X11Blur::availabilityChanged, this, [this] {
            const bool b = blurAvailable();
            if (b != lastBlur_) { lastBlur_ = b; emit blurAvailableChanged(); }
        });
    }
#endif
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
    connect(geoReceiver_, &GeometryReceiver::miniReported,
            this, &WindowController::miniPosition);
    connect(geoReceiver_, &GeometryReceiver::resizeStarted,
            this, &WindowController::interactiveStarted);
    connect(geoReceiver_, &GeometryReceiver::moveStarted,
            this, &WindowController::interactiveMoveStarted);
    connect(geoReceiver_, &GeometryReceiver::windowReported,
            this, &WindowController::windowGeometry);
    connect(geoReceiver_, &GeometryReceiver::popupCursorReported,
            this, &WindowController::popupCursor);
    connect(geoReceiver_, &GeometryReceiver::popupWindowReported,
            this, &WindowController::popupWindow);
    connect(geoReceiver_, &GeometryReceiver::popupRoomReported,
            this, &WindowController::popupRoom);
    // loaded before any window exists, so none reaches the taskbar
    if (kwinAvailable_) watchPopupWindows(true);
#ifdef MELO_X11
    // the windows KWin's scripts set the opacity of are left to them
    if (isX11_)
        x11HideUntilDrawn(kwinAvailable_ ? QStringList{QStringLiteral("melo"), QStringLiteral("melo-mini"),
                                                      QStringLiteral("melo-queue"), QStringLiteral("melo-vis"),
                                                      QStringLiteral("melo-video")}
                                         : QStringList{});
    // without KWin's script, melo stays one taskbar entry through the EWMH hint
    if (isX11_ && !kwinAvailable_)
        x11SkipTaskbar({QStringLiteral("melo-mini"), QStringLiteral("melo-queue"),
                        QStringLiteral("melo-vis"), QStringLiteral("melo-video")});
#endif
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
    unload(pinHoldScriptId_, pinHoldScriptPath_, pinHoldScriptName_);
    unload(popupWatchId_, popupWatchPath_, popupWatchName_);
    unload(alwaysUpScriptId_, alwaysUpScriptPath_, alwaysUpScriptName_);
}

#ifdef MELO_X11
// the shape WindowShapeItem holds back while a resize is in progress is the whole plane
static QRegion heldShape(QQuickWindow* win) {
    return win->property("meloShapeHeld").toBool() ? QRegion() : win->property("meloShape").value<QRegion>();
}
#endif

void WindowController::setInputEnabled(QQuickWindow* win, bool enabled) {
    if (!win) return;
#ifdef MELO_X11
    // setMask is the X bounding shape, which clips drawing too. KWin reveals a
    // window by opacity in one script, and a window still shaped off-surface
    // would show nothing until its mask call reached the X server.
    if (isX11_ && kwinAvailable_) {
        win->setProperty("meloInputOff", false);
        win->setMask(meloWindowMask(heldShape(win)));
        const QRegion none;
        x11SetInputShape(win, enabled ? nullptr : &none);
        return;
    }
#endif
    // Input back is the window's shape (WindowShapeItem keeps it on the
    // window), not the whole rectangle, which a null QRegion is; a region
    // fully off the surface makes every pixel click-through.
    win->setProperty("meloInputOff", !enabled);
    win->setMask(enabled ? meloWindowMask(win->property("meloShape").value<QRegion>())
                         : QRegion(-100, -100, 1, 1));
}

void WindowController::setInputRegion(QQuickWindow* win, int x, int y, int w, int h) {
    if (!win) return;
#ifdef MELO_X11
    if (isX11_ && kwinAvailable_) {   // see setInputEnabled
        win->setProperty("meloInputOff", false);
        win->setMask(meloWindowMask(heldShape(win)));
        const QRegion r(x, y, w, h);
        x11SetInputShape(win, &r);
        return;
    }
#endif
    // a region of the caller's own, which a shape change must not replace
    win->setProperty("meloInputOff", true);
    win->setMask(QRegion(x, y, w, h));
}

// A rounded-rect region so the blur follows the window's rounded corners
// instead of frosting the square area behind them. r<=0 -> plain rect.
// Only setBlurRegion calls this, and only on the two paths that have a
// compositor to call — the stub build below has neither.
#if defined(MELO_OWN_BLUR) || defined(HAVE_KWINDOWSYSTEM)
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
#ifdef MELO_OWN_BLUR
// Wayland first (a MELO_NATIVE_BLUR build), then the X11 property (MELO_X11);
// each instance() is null off its platform.
void WindowController::setBlurBehind(QQuickWindow* win, bool on) {
    if (!win) return;
    // An empty region means the whole surface and follows every resize by itself.
    // A rounded region would need re-cutting on every resize, committed on a
    // frame, to keep blur off 3.4 px² per corner at a 4px radius, which the
    // window paints its own rounded background over anyway. A shaped window is the
    // exception: WindowShapeItem re-cuts "meloShape" on every resize and
    // the backend re-sends it.
    const QRegion shape = win->property("meloShape").value<QRegion>();
#ifdef MELO_NATIVE_BLUR
    if (auto* wb = WaylandBlur::instance()) { wb->setBlur(win, on, shape, true); return; }
#endif
#ifdef MELO_X11
    if (auto* xb = X11Blur::instance()) xb->setBlur(win, on, shape, true);
#endif
}
void WindowController::setBlurRegion(QQuickWindow* win, int x, int y, int w, int h) {
    if (!win) return;
    const QRegion r = roundedRegion(x, y, w, h, blurRadius_);
#ifdef MELO_NATIVE_BLUR
    if (auto* wb = WaylandBlur::instance()) { wb->setBlur(win, true, r); return; }
#endif
#ifdef MELO_X11
    if (auto* xb = X11Blur::instance()) xb->setBlur(win, true, r);
#endif
}
// Contrast is Wayland-only here: KWin 6.6 and older, through its own protocol.
void WindowController::setBackgroundContrast(QQuickWindow* win, bool on,
                                             double contrast, double saturation) {
#ifdef MELO_NATIVE_BLUR
    auto* wb = WaylandBlur::instance();
    if (!wb || !win) return;
    // Neutral values send no contrast object: KWin treats its mere existence as
    // an override, so sending 1.0 would replace the user's global blur
    // saturation for melo's window alone.
    const bool neutral = qFuzzyCompare(contrast, 1.0) && qFuzzyCompare(saturation, 1.0);
    wb->setContrast(win, on && !neutral, contrast, saturation, QRegion());
#else
    Q_UNUSED(win) Q_UNUSED(on) Q_UNUSED(contrast) Q_UNUSED(saturation)
#endif
}
bool WindowController::blurAvailable() const {
#ifdef MELO_NATIVE_BLUR
    if (auto* wb = WaylandBlur::instance()) return wb->available();
#endif
#ifdef MELO_X11
    if (auto* xb = X11Blur::instance()) return xb->available();
#endif
    return false;
}
// On Wayland the bound contrast global is the answer. The D-Bus effect list
// counts only without a Wayland connection, and never on X11, where melo
// sends no contrast.
bool WindowController::contrastAvailable() const {
#ifdef MELO_NATIVE_BLUR
    if (auto* wb = WaylandBlur::instance()) return wb->contrastAvailable();
#endif
    return isX11_ ? false : contrastAvailable_;
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
// Read when asked, never announced: KWindowEffects has no change signal.
bool WindowController::blurAvailable() const {
    return KWindowEffects::isEffectAvailable(KWindowEffects::BlurBehind);
}
bool WindowController::contrastAvailable() const {
    return KWindowEffects::isEffectAvailable(KWindowEffects::BackgroundContrast);
}
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

void WindowController::showFile(const QString& path) {
    if (meloRefuseFromPlugin("WindowCtl.showFile")) return;
    const QUrl folder = QUrl::fromLocalFile(QFileInfo(path).absolutePath());
    auto* bus = QDBusConnection::sessionBus().interface();
    const QString fm = QStringLiteral("org.freedesktop.FileManager1");
    if (!bus || !(bus->isServiceRegistered(fm).value() || bus->activatableServiceNames().value().contains(fm))) {
        QDesktopServices::openUrl(folder);
        return;
    }
    QDBusMessage m = QDBusMessage::createMethodCall(fm, QStringLiteral("/org/freedesktop/FileManager1"), fm,
                                                    QStringLiteral("ShowItems"));
    m << QStringList{QUrl::fromLocalFile(path).toString()} << QString();
    auto* w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 5000), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [w, folder] {
        if (w->isError()) QDesktopServices::openUrl(folder);
        w->deleteLater();
    });
}

// Run a KWin script. Unique path and unique name per call: KWin keys its
// registry on the name (see kwinScriptName), so reusing one is a silent -1.
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

// KWin units per Qt unit, as a JS expression. Wayland: both are logical
// pixels. X11: KWin counts X pixels over its Xwayland scale (1 on Plasma X11),
// Qt counts X pixels over its DPR from Xft.dpi, and they need not match (1.9
// against 1.75 on a 1.9 output with Xft.dpi 168). Both span the same desktop,
// so its width in each is the ratio. Every coordinate into or out of a script
// goes through it, so melo sees Qt units only.
static QString kwinScaleJs() {
    if (QGuiApplication::platformName() != QLatin1String("xcb")) return QStringLiteral("1");
    const QScreen* screen = QGuiApplication::primaryScreen();
    const int qtW = screen ? screen->virtualSize().width() : 0;
    if (qtW <= 0) return QStringLiteral("1");
    return QStringLiteral("(workspace.virtualScreenSize.width / %1)").arg(qtW);
}

// Captions are the identity, so every melo window needs a title: X11 captions
// an untitled one "melo" (Qt falls back to the application name), and KWin
// then matches it as the main window.
static QString findWindowsPrelude() {
    return QStringLiteral(
        "const k = %2;\n"
        "let main = null, mini = null, mq = null;\n"
        "const pws = {};\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %1) continue;\n"
        "  if (w.caption === \"melo\") main = w;\n"
        "  else if (w.caption === \"melo-mini\") mini = w;\n"
        "  else if (w.caption === \"melo-mini-queue\") mq = w;\n"
        "  else if ([\"melo-queue\", \"melo-vis\", \"melo-video\"].includes(w.caption)) pws[w.caption] = w;\n"
        "}\n").arg(QString::number(QCoreApplication::applicationPid()), kwinScaleJs());
}

bool WindowController::alignForCollapse(int barHeight) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main && mini) {\n"
        "  const g = main.frameGeometry;\n"
        "  mini.frameGeometry = { x: g.x, y: g.y + g.height - %1 * k, width: g.width, height: %1 * k };\n"
        "}\n").arg(barHeight));
}

bool WindowController::alignForExpand(int barHeight, int width, int height) {
    if (!kwinAvailable_) return false;
    // Whose width wins: the caller's, since QML may have just set a width
    // the compositor has not seen, and g.width would write the mini bar's
    // width back over it.
    const QString w = width > 0 ? QString::number(width) + QStringLiteral(" * k")
                                : QStringLiteral("g.width");
    const QString h = height > 0 ? QString::number(height) + QStringLiteral(" * k")
                                 : QStringLiteral("g.height");
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main && mini) {\n"
        "  const m = mini.frameGeometry;\n"
        "  const g = main.frameGeometry;\n"
        "  const h = %3;\n"
        "  main.frameGeometry = { x: m.x, y: m.y + %1 * k - h, width: %2, height: h };\n"
        "}\n").arg(QString::number(barHeight), w, h));
}

// The popup host's rectangle for a side, shared with the glue script; and the
// room above the bar, reported to melo.
// On X11 the host spans the work area: KWin shows a moved X window's old picture
// until it redraws, so a host moved at each drag's start and end would flash.
static QString popupHostJs(const QString& service, bool wide) {
    return QStringLiteral(
        "const wideHost = %2;\n"
        "function hostRect(side) {\n"
        "  const m = mini.frameGeometry;\n"
        "  const a = workspace.clientArea(KWin.MaximizeArea, mini);\n"
        "  const foot = m.y + m.height, h = Math.max(a.height, foot - a.y);\n"
        "  let x = m.x, w = m.width;\n"
        "  if (wideHost) { x = Math.min(a.x, m.x); w = Math.max(a.x + a.width, m.x + m.width) - x; }\n"
        "  else if (side === \"left\") { x = Math.min(a.x, m.x); w = m.x + m.width - x; }\n"
        "  else if (side === \"right\") { w = Math.max(a.x + a.width, m.x + m.width) - m.x; }\n"
        "  return { x: x, y: foot - h, width: w, height: h };\n"
        "}\n"
        "function reportRoom() {\n"
        "  const m = mini.frameGeometry, a = workspace.clientArea(KWin.MaximizeArea, mini);\n"
        "  callDBus(\"%1\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportPopupRoom\",\n"
        "           String(Math.round((m.y + m.height - a.y) / k)));\n"
        "}\n").arg(service, wide ? QStringLiteral("true") : QStringLiteral("false"));
}

// a caption as a JS string literal, from melo's own fixed set
static QString jsCaption(const QString& c) {
    static const QStringList known{QStringLiteral("melo-queue"), QStringLiteral("melo-vis"), QStringLiteral("melo-video")};
    return known.contains(c) ? QStringLiteral("\"%1\"").arg(c) : QStringLiteral("\"\"");
}

bool WindowController::placePopupWindowOverMain(const QString& caption, int rx, int ry) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "const pw = pws[%3];\n"
        "if (main && pw) {\n"
        "  const g = main.frameGeometry, p = pw.frameGeometry;\n"
        "  pw.frameGeometry = { x: g.x + %1 * k, y: g.y + %2 * k, width: p.width, height: p.height };\n"
        "}\n").arg(QString::number(rx), QString::number(ry), jsCaption(caption)));
}

bool WindowController::swapPopupWindows(const QString& from, const QString& to) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "const a = pws[%1], b = pws[%2];\n"
        "if (a && b) {\n"
        "  b.frameGeometry = a.frameGeometry;\n"
        "  b.opacity = 1; a.opacity = 0;\n"
        "}\n").arg(jsCaption(from), jsCaption(to)));
}

bool WindowController::placePopupWindowBeside(const QString& caption) {
    if (!kwinAvailable_) return false;
    QString c = caption;
    c.replace(QLatin1Char('"'), QString());
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "const kinds = [\"melo-queue\", \"melo-vis\", \"melo-video\"];\n"
        "let me = null; const others = [];\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %2 || kinds.indexOf(w.caption) < 0) continue;\n"
        "  if (w.caption === \"%1\") me = w; else if (w.opacity > 0.5) others.push(w);\n"
        "}\n"
        "if (me && others.length) {\n"
        "  const g = me.frameGeometry, a = workspace.clientArea(KWin.MaximizeArea, me), gap = 12 * k;\n"
        "  const free = (x, y) => x >= a.x && y >= a.y && x + g.width <= a.x + a.width && y + g.height <= a.y + a.height\n"
        "    && others.every(o => { const r = o.frameGeometry; return x + g.width <= r.x || r.x + r.width <= x || y + g.height <= r.y || r.y + r.height <= y; });\n"
        "  let spot = null;\n"
        "  for (const o of others) {\n"
        "    const r = o.frameGeometry;\n"
        "    for (const [x, y] of [[r.x + r.width + gap, r.y], [r.x - g.width - gap, r.y], [r.x, r.y - g.height - gap], [r.x, r.y + r.height + gap]])\n"
        "      if (!spot && free(x, y)) spot = [x, y];\n"
        "  }\n"
        "  if (!spot) { const r = others[others.length - 1].frameGeometry; spot = [r.x + 40 * k, r.y + 40 * k]; }\n"
        "  me.frameGeometry = { x: spot[0], y: spot[1], width: g.width, height: g.height };\n"
        "}\n").arg(c, QString::number(QCoreApplication::applicationPid())));
}

bool WindowController::watchPopupWindows(bool on, bool hideMain) {
    if (!kwinAvailable_) return false;
    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    if (!on || popupWatchId_ >= 0) {
        if (popupWatchId_ >= 0) {
            const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(popupWatchId_), "org.kde.kwin.Script");
            runner.call("stop");
            scripting.call("unloadScript", popupWatchName_);
            QFile::remove(popupWatchPath_);
            popupWatchId_ = -1;
            popupWatchName_.clear();
        }
        if (!on) return true;
    }
    static int seq = 0;
    popupWatchPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                      + QStringLiteral("/melo-kwin-popup-%1-%2.js")
                            .arg(QCoreApplication::applicationPid()).arg(++seq);
    popupWatchName_ = kwinScriptName(popupWatchPath_);
    QFile f(popupWatchPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    // Near the bar: its foot within 80 px of the bar's top, either side, and over
    // at least a third of the bar's width. The bar is looked up per report: the
    // script loads at startup, before the bar's window exists.
    f.write((findWindowsPrelude() + QStringLiteral(
        "function report(w) {\n"
        "  const p = w.frameGeometry;\n"
        "  let near = 0;\n"
        "  if (!mini) mini = workspace.windowList().find(x => x.pid === w.pid && x.caption === \"melo-mini\") || null;\n"
        "  if (mini) {\n"
        "    const m = mini.frameGeometry;\n"
        "    const over = Math.min(p.x + p.width, m.x + m.width) - Math.max(p.x, m.x);\n"
        "    if (Math.abs(p.y + p.height - m.y) < 80 * k && over > m.width / 3) near = 1;\n"
        "  }\n"
        "  callDBus(\"%1\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportPopupWindow\",\n"
        "           [w.caption].concat([p.x / k, p.y / k, p.width / k, p.height / k, near].map(Math.round)).join(\",\"));\n"
        "}\n"
        // melo is the one taskbar entry; a transparent window stays out of Alt+Tab too
        "function list(w) { w.skipTaskbar = true; w.skipPager = true; w.skipSwitcher = w.opacity < 0.5; }\n"
        "function hook(w) {\n"
        "  if (w && w.pid === %2 && ([\"melo-mini\", \"melo-queue\", \"melo-vis\", \"melo-video\"].includes(w.caption)\n"
        "                            || w.caption.startsWith(\"melo-plugin-\"))) {\n"
        "    list(w);\n"
        "    w.opacityChanged.connect(() => list(w));\n"
        "  }\n"
        "  if (w && w.pid === %2 && [\"melo-queue\", \"melo-vis\", \"melo-video\"].includes(w.caption))\n"
        "  {\n"
        "    w.interactiveMoveResizeFinished.connect(() => report(w));\n"
        // MELO_GEOM_DEBUG: each size KWin asks for through a resize, for the trace
        "    if (%3) w.interactiveMoveResizeStepped.connect((g) => callDBus(\"%1\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportStep\",\n"
        "      [w.caption, Math.round(g.width / k), Math.round(g.height / k), Date.now()].join(\",\")));\n"
        "    if (%3) w.frameGeometryChanged.connect(() => { if (!w.resize) return; const p = w.frameGeometry;\n"
        "      callDBus(\"%1\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportPlace\",\n"
        "        [w.caption, p.x / k, p.y / k, p.width / k, p.height / k, Date.now()].map((v, i) => i === 0 ? v : Math.round(v * 10) / 10).join(\",\")); });\n"
        "  }\n"
        "}\n"
        "for (const w of workspace.windowList()) hook(w);\n"
        // The bar and the detached windows map hidden; on X11 a window shows black
        // until melo has drawn it and set its opacity, so they start at 0 and melo
        // reveals them. Only for a new window: this script reloads at startup over
        // windows already shown.
        "workspace.windowAdded.connect((w) => {\n"
        "  if (w && w.pid === %2 && [\"melo-mini\", \"melo-queue\", \"melo-vis\", \"melo-video\"].includes(w.caption)) w.opacity = 0;\n"
        "  if (w && w.pid === %2 && w.caption === \"melo\" && %4) w.opacity = 0;\n"
        "  hook(w);\n"
        "});\n").arg(geoService_, QString::number(QCoreApplication::applicationPid()),
                                                 qEnvironmentVariableIsSet("MELO_GEOM_DEBUG") ? QStringLiteral("true") : QStringLiteral("false"),
                                                 isX11_ || hideMain ? QStringLiteral("true") : QStringLiteral("false"))).toUtf8());
    f.close();
    QDBusReply<int> id = scripting.call("loadScript", popupWatchPath_, popupWatchName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(popupWatchName_, id);
        popupWatchName_.clear();
        return false;
    }
    popupWatchId_ = id.value();
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(popupWatchId_), "org.kde.kwin.Script");
    runner.call("run");
    return true;
}

bool WindowController::fitPopupHost(const QString& side) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + popupHostJs(geoService_, isX11_) + QStringLiteral(
        "if (main && mini) { main.frameGeometry = hostRect(\"%1\"); reportRoom(); }\n").arg(side));
}

void WindowController::restackBelow(QQuickWindow* win, QQuickWindow* sibling) {
#ifdef MELO_X11
    if (isX11_) x11RestackBelow(win, sibling);
#else
    Q_UNUSED(win) Q_UNUSED(sibling)
#endif
}

QString WindowController::stackOrder(QQuickWindow* a, QQuickWindow* b) {
#ifdef MELO_X11
    if (isX11_) return x11StackOrder({a, b});
#else
    Q_UNUSED(a) Q_UNUSED(b)
#endif
    return QString();
}

// Qt 6.12's Wayland EGL context resizes the EGL window inside makeCurrent, after
// eglMakeCurrent: on NVIDIA the frame being drawn keeps the old size's back buffer and
// is committed with the new size's ack and viewport, so KWin scales the old picture into
// the new place and the far edge deforms through a drag (37 of 51 commits one size
// behind). A window-sized offscreen pass (main's layers, projectM's FBO) makes the window
// current a second time, which hides it. When the size has changed since the last frame,
// make it current once more before drawing, which takes the new buffer. X11 (Mesa) draws
// the first frame after a resize in the old buffer too, and GLX skips a bind to what is
// already current: it unbinds first.
// MELO_X11_REBIND=0 leaves X11 to the present sync alone.
void WindowController::keepBufferInStep(QQuickWindow* win) {
    if (!win) return;
    bool rebind = false;
#ifdef MELO_X11
    if (isX11_) {
        x11PresentSync(win);
        if (qEnvironmentVariable("MELO_X11_REBIND") == QLatin1String("0")) return;
        rebind = true;
    }
#endif
    if (!rebind && !QGuiApplication::platformName().startsWith(QLatin1String("wayland"))) return;
    auto last = std::make_shared<QSize>();
    connect(win, &QQuickWindow::beforeRendering, win, [win, last, rebind] {
        const QSize now = win->size() * win->devicePixelRatio();
        if (now == *last) return;
        *last = now;
        QOpenGLContext* c = QOpenGLContext::currentContext();
        if (!c) return;
        if (rebind) c->doneCurrent();
        c->makeCurrent(win);
    }, Qt::DirectConnection);
}

void WindowController::startSystemMove(QQuickWindow* win, QQuickWindow* from) {
    if (!win) return;
#ifdef MELO_X11
    if (isX11_ && x11StartSystemResize(win, Qt::Edges())) {
        if (from) {
            const QPointF g = QCursor::pos();
            QCoreApplication::postEvent(from, new QMouseEvent(QEvent::MouseButtonRelease,
                from->mapFromGlobal(g), g, Qt::LeftButton, Qt::NoButton, Qt::NoModifier));
        }
        return;
    }
#else
    Q_UNUSED(from)
#endif
    win->startSystemMove();
}

void WindowController::startSystemResize(QQuickWindow* win, int edges, QQuickWindow* from) {
    if (!win) return;
#ifdef MELO_X11
    if (isX11_ && x11StartSystemResize(win, Qt::Edges(edges))) {
        if (from) {
            const QPointF g = QCursor::pos();
            // posted: the press that called this is still being delivered
            QCoreApplication::postEvent(from, new QMouseEvent(QEvent::MouseButtonRelease,
                from->mapFromGlobal(g), g, Qt::LeftButton, Qt::NoButton, Qt::NoModifier));
        }
        return;
    }
#endif
    win->startSystemResize(Qt::Edges(edges));
}

// N-window opacity in one script execution. Not findWindowsPrelude(), which
// hardcodes the built-in captions, but its pid guard is kept: instances share
// captions, and one melo would otherwise set another's opacity.
bool WindowController::setWindowOpacities(const QVariantList& windows) {
    if (!kwinAvailable_) return false;
    // caption -> opacity as a JSON object literal (valid JS, and it quotes
    // arbitrary plugin-supplied titles) — see the U+2028 note below for the
    // one thing JSON does not do for us.
    QJsonObject want;
    for (const QVariant& v : windows) {
        const QVariantMap m = v.toMap();
        const QString title = m.value(QStringLiteral("title")).toString();
        const QVariant op = m.value(QStringLiteral("opacity"));
        bool numeric = false;
        const double opacity = op.toDouble(&numeric);
        // A malformed entry is dropped, not read as 0: 0 would hide the window
        // mid-swap.
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
        // or "constructor" would be assigned a function as its opacity.
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
        "const k = %3;\n"
        "for (const w of workspace.windowList()) {\n"
        "  if (w.pid !== %2) continue;\n"
        "  if (!Object.prototype.hasOwnProperty.call(want, w.caption)) continue;\n"
        "  const p = want[w.caption];\n"
        "  const g = w.frameGeometry;\n"
        "  w.frameGeometry = { x: p.x * k, y: p.y * k, width: g.width, height: g.height };\n"
        "}\n")
        .arg(json, QString::number(QCoreApplication::applicationPid()), kwinScaleJs()));
}

bool WindowController::raisePopupWindow(const QString& caption) {
    if (!kwinAvailable_ || caption.isEmpty()) return false;
    QString lit = QString::fromUtf8(QJsonDocument(QJsonArray{caption}).toJson(QJsonDocument::Compact));
    lit.replace(QChar(0x2028), QLatin1String("\\u2028"));
    lit.replace(QChar(0x2029), QLatin1String("\\u2029"));
    return runKwinScript(QStringLiteral(
        "const cap = %1[0];\n"
        "for (const w of workspace.windowList())\n"
        "  if (w.pid === %2 && w.caption === cap) workspace.raiseWindow(w);\n")
        .arg(lit, QString::number(QCoreApplication::applicationPid())));
}

// pin mode "flag": on X11 the window manager's state itself (x11SetKeepAbove), since
// toggling the Qt flag gives the window a new X window on its next show
static void setFlagAbove(QWindow* w, bool on) {
#ifdef MELO_X11
    if (x11SetKeepAbove(w, on)) return;
#endif
    w->setFlag(Qt::WindowStaysOnTopHint, on);
}

bool WindowController::setKeepAbove(bool on) {
    if (pinMode_ == QLatin1String("flag")) {
        bool any = false;
        for (QWindow* w : QGuiApplication::topLevelWindows()) {
            const QString t = w->title();
            if (t != QLatin1String("melo") && t != QLatin1String("melo-mini")) continue;
            setFlagAbove(w, on);
            any = true;
        }
        return any;
    }
    if (pinMode_ != QLatin1String("kwin") || !kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) main.keepAbove = %1;\n"
        "if (mini) mini.keepAbove = %1;\n").arg(on ? "true" : "false"));
}

bool WindowController::setWindowKeepAbove(QQuickWindow* win, bool on) {
    if (!win) return false;
    if (pinMode_ == QLatin1String("flag")) { setFlagAbove(win, on); return true; }
    if (pinMode_ != QLatin1String("kwin") || !kwinAvailable_) return false;
    if (on) installPinHold();
    QString t = win->title();
    t.replace(QLatin1Char('"'), QString());
    return runKwinScript(QStringLiteral(
        "for (const w of workspace.windowList())\n"
        "  if (w.pid === %1 && w.caption === \"%2\") w.keepAbove = %3;\n")
        .arg(QString::number(QCoreApplication::applicationPid()), t, on ? "true" : "false"));
}

// KWin raises a clicked transient's main window and all its transients with
// it. While a kept-above melo window is active, other apps' windows the main
// window passes go back over it, in their old order.
void WindowController::installPinHold() {
    if (pinHoldScriptId_ >= 0) return;
    static int seq = 0;
    pinHoldScriptPath_ = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                         + QStringLiteral("/melo-kwin-pinhold-%1-%2.js")
                               .arg(QCoreApplication::applicationPid()).arg(++seq);
    pinHoldScriptName_ = kwinScriptName(pinHoldScriptPath_);
    QFile f(pinHoldScriptPath_);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        pinHoldScriptName_.clear();
        pinHoldScriptPath_.clear();
        return;
    }
    f.write(QStringLiteral(
        "const pid = %1;\n"
        "let prev = workspace.stackingOrder.slice();\n"
        "let fixing = false;\n"
        "const changed = () => {\n"
        "  if (fixing) return;\n"
        "  const now = workspace.stackingOrder;\n"
        "  const a = workspace.activeWindow;\n"
        "  if (a && a.pid === pid && a.keepAbove && a.transientFor) {\n"
        "    const main = a.transientFor;\n"
        "    const was = prev.indexOf(main), at = now.indexOf(main);\n"
        "    const over = was < 0 ? [] : prev.slice(was + 1).filter((w) =>\n"
        "      w.pid !== pid && !w.keepAbove && now.indexOf(w) >= 0 && now.indexOf(w) < at);\n"
        "    fixing = true;\n"
        "    for (const w of over) workspace.raiseWindow(w);\n"
        "    fixing = false;\n"
        "  }\n"
        "  prev = workspace.stackingOrder.slice();\n"
        "};\n"
        // workspace has no stacking signal in scripts; every window has one
        "const arm = (w) => w.stackingOrderChanged.connect(changed);\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(QCoreApplication::applicationPid()).toUtf8());
    f.close();

    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    QDBusReply<int> id = scripting.call("loadScript", pinHoldScriptPath_, pinHoldScriptName_);
    if (!id.isValid() || id.value() < 0) {
        warnLoadRefused(pinHoldScriptName_, id);
        QFile::remove(pinHoldScriptPath_);
        pinHoldScriptName_.clear();
        pinHoldScriptPath_.clear();
        return;
    }
    pinHoldScriptId_ = id.value();
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(pinHoldScriptId_), "org.kde.kwin.Script");
    runner.call("run");
}

#ifdef MELO_NATIVE_BLUR
bool WindowController::showWindowMenu(QQuickWindow* win, int x, int y) {
    if (pinMode_ != QLatin1String("menu") || !win || !isWayland_) return false;
    auto* ni = QGuiApplication::platformNativeInterface();
    if (!ni) return false;
    auto* top = static_cast<xdg_toplevel*>(ni->nativeResourceForWindow("xdg_toplevel", win));
    auto* seat = static_cast<wl_seat*>(ni->nativeResourceForIntegration("wl_seat"));
    auto* display = static_cast<wl_display*>(ni->nativeResourceForIntegration("wl_display"));
    if (!top || !seat) return false;
    const auto serial = uint32_t(quintptr(ni->nativeResourceForIntegration("serial")));
    xdg_toplevel_show_window_menu(top, seat, serial, x, y);
    if (display) wl_display_flush(display);
    return true;
}
#else
bool WindowController::showWindowMenu(QQuickWindow*, int, int) { return false; }
#endif

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
    // Keeps main's foot on the bar's through moves and resizes. A host melo widened
    // for a drag (fitPopupHost) stays put through it and after it: the popup in it is
    // drawn against the bar's fixed side, from the bar's own width.
    f.write((findWindowsPrelude() + popupHostJs(geoService_, isX11_) + QStringLiteral(
        "let lastBarX = null;\n"
        "function glue() {\n"
        "  if (!mini || !main) return;\n"
        "  const m = mini.frameGeometry;\n"
        "  const g = main.frameGeometry;\n"
        // A move carries the host with the bar, so its picture never changes. A host
        // fitted for a resize stays put through it; one that was not (a resize KWin
        // started, Alt+drag) follows the bar per step.
        "  const resizing = mini.resize;\n"
        "  const dx = (lastBarX === null || resizing) ? 0 : m.x - lastBarX;\n"
        "  lastBarX = m.x;\n"
        "  if (resizing && g.width > m.width + 1) return;\n"
        "  const nx = resizing ? m.x : g.x + dx, ny = m.y + m.height - g.height;\n"
        "  if (g.x === nx && g.y === ny) return;   // skip no-op moves\n"
        "  main.frameGeometry = { x: nx, y: ny, width: g.width, height: g.height };\n"
        "}\n"
        // The host stays where the move or resize left it: fitting it back to the bar here
        // would move it before melo draws there, and KWin would show its last frame in the
        // new place. Only the room above the bar is refreshed.
        "function settle() {\n"
        "  if (!mini || !main) return;\n"
        "  const g = main.frameGeometry, r = hostRect(\"\");\n"
        "  if (r.height !== g.height || r.y !== g.y) main.frameGeometry = { x: g.x, y: r.y, width: g.width, height: r.height };\n"
        "  reportRoom();\n"
        "}\n"
        // KWin holds the pointer through the bar's resize, so a popup corner's
        // height comes from here: the cursor over the bar's top, once per pixel.
        "let lastAbove = null;\n"
        "function cursorAbove() {\n"
        "  if (!mini || !mini.resize) { lastAbove = null; return; }\n"
        "  const above = Math.round((mini.frameGeometry.y - workspace.cursorPos.y) / k);\n"
        "  if (above === lastAbove) return;\n"
        "  lastAbove = above;\n"
        "  callDBus(\"%1\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportPopupCursor\", String(above));\n"
        "}\n"
        "if (mini && main) {\n"
        "  glue();\n"
        "  mini.frameGeometryChanged.connect(glue);\n"
        "  mini.interactiveMoveResizeFinished.connect(settle);   // the bar's span again, as tall as fits\n"
        "  workspace.cursorPosChanged.connect(cursorAbove);\n"
        "}\n").arg(geoService_)).toUtf8());
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

QString WindowController::pluginWindowGlueScript(const QVariantList& input, qint64 pid,
                                                 const QString& scale) {
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
        "const k = %3;\n"
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
        "    const nx = g.x + link.dx * k, ny = g.y + link.dy * k;\n"
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
        .arg(json, QString::number(pid), scale);
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
    const QString body = pluginWindowGlueScript(links, QCoreApplication::applicationPid(),
                                                kwinScaleJs());
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
        "const k = %3;\n"
        "let main = null, mini = null;\n"
        "const report = () => {\n"
        "  if (!main) return;\n"
        "  const g = main.frameGeometry;\n"
        "  const q = (v) => Math.round(v / k);\n"
        "  const c = workspace.cursorPos;\n"
        "  const inR = (r) => c.x >= r.x && c.x <= r.x + r.width\n"
        "                  && c.y >= r.y && c.y <= r.y + r.height;\n"
        "  const inside = inR(g) || (mini && inR(mini.frameGeometry)) ? 1 : 0;\n"
        "  callDBus(\"%2\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"Report\",\n"
        "           q(g.x) + \",\" + q(g.y) + \",\" + q(g.width) + \",\" + q(g.height) + \",\" + inside\n"
        "           + (mini ? \",\" + q(mini.frameGeometry.x) + \",\" + q(mini.frameGeometry.y) : \"\"));\n"
        "};\n"
        "const started = (w) => {\n"
        // Which one it is: KWin sets `resize` on the window for the length
        // of an interactive resize and leaves it false for a move, which
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
        "  if (%4) w.interactiveMoveResizeStepped.connect((g) => callDBus(\"%2\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportStep\",\n"
        "    [w.caption, Math.round(g.width / k), Math.round(g.height / k), Date.now()].join(\",\")));\n"
        "  if (%4) w.frameGeometryChanged.connect(() => { if (!w.resize) return; const p = w.frameGeometry;\n"
        "    callDBus(\"%2\", \"/melo/geometry\", \"com.melo.Geometry\", \"ReportPlace\",\n"
        "      [w.caption, p.x / k, p.y / k, p.width / k, p.height / k, Date.now()].map((v, i) => i === 0 ? v : Math.round(v * 10) / 10).join(\",\")); });\n"
        // The handler is shared by melo and the compact bar, so it is told
        // which window raised it rather than assuming main.
        "  w.interactiveMoveResizeStarted.connect(() => started(w));\n"
        "  report();\n"
        "};\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(QString::number(QCoreApplication::applicationPid()), geoService_,
             kwinScaleJs(), qEnvironmentVariableIsSet("MELO_GEOM_DEBUG") ? QStringLiteral("true") : QStringLiteral("false"))).toUtf8());
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
        "  const q = (v) => Math.round(v / k);\n"
        "  const c = workspace.cursorPos;\n"
        "  const inR = (r) => c.x >= r.x && c.x <= r.x + r.width\n"
        "                  && c.y >= r.y && c.y <= r.y + r.height;\n"
        "  const inside = inR(g) || (mini && inR(mini.frameGeometry)) ? 1 : 0;\n"
        "  callDBus(\"%1\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"Report\",\n"
        "           q(g.x) + \",\" + q(g.y) + \",\" + q(g.width) + \",\" + q(g.height) + \",\" + inside\n"
        "           + (mini ? \",\" + q(mini.frameGeometry.x) + \",\" + q(mini.frameGeometry.y) : \"\"));\n"
        "}\n").arg(geoService_));
}

// The per-window watcher's body. Caption handling is setWindowOpacities's: JSON
// literal, U+2028/U+2029 escape, own-property lookup, pid guard, single-pass
// arg(). Also armed by windowAdded: on Wayland a just-mapped window may not be
// in windowList() yet.
QString WindowController::windowGeometryScript(const QStringList& captions,
                                               qint64 pid, const QString& service,
                                               const QString& scale) {
    QJsonObject want;
    for (const QString& c : captions) if (!c.isEmpty()) want.insert(c, 1);
    QString json = QString::fromUtf8(QJsonDocument(want).toJson(QJsonDocument::Compact));
    json.replace(QChar(0x2028), QLatin1String("\\u2028"));
    json.replace(QChar(0x2029), QLatin1String("\\u2029"));

    return QStringLiteral(
        "const want = %1;\n"
        "const k = %4;\n"
        // One string, never five arguments: callDBus marshals a JS number as a
        // D-Bus double, which silently fails to match an int slot (see
        // GeometryReceiver in WindowController.h). The caption goes first and
        // ReportWindow takes the last four fields as the numbers, so a comma
        // in it survives.
        "const report = (w) => {\n"
        "  const g = w.frameGeometry;\n"
        "  const q = (v) => Math.round(v / k);\n"
        "  callDBus(\"%3\", \"/melo/geometry\",\n"
        "           \"com.melo.Geometry\", \"ReportWindow\",\n"
        "           w.caption + \",\" + q(g.x) + \",\" + q(g.y) + \",\"\n"
        "                     + q(g.width) + \",\" + q(g.height));\n"
        "};\n"
        "const arm = (w) => {\n"
        "  if (w.pid !== %2) return;\n"
        "  if (!Object.prototype.hasOwnProperty.call(want, w.caption)) return;\n"
        "  w.interactiveMoveResizeFinished.connect(() => report(w));\n"
        // Once now, so the host learns where the compositor actually put a
        // window rather than only where melo asked for it to go. The host
        // treats a window's first report as adoption, not as a drag.
        "  report(w);\n"
        "};\n"
        "for (const w of workspace.windowList()) arm(w);\n"
        "workspace.windowAdded.connect(arm);\n")
        .arg(json, QString::number(pid), service, scale);
}

void WindowController::unloadWindowWatcher() {
    if (winWatchScriptId_ < 0) return;
    const KWinObject scripting("/Scripting", "org.kde.kwin.Scripting");
    const KWinObject runner(QStringLiteral("/Scripting/Script%1").arg(winWatchScriptId_), "org.kde.kwin.Script");
    runner.call("stop");
    // By name, never by path (see kwinScriptName()): unloadScript(path) matches
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
        scripting.call("unloadScript", alwaysUpScriptName_);   // by name; see kwinScriptName()
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
                                              geoService_, kwinScaleJs());
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

// areaAt: the work area of the screen under the rectangle's centre, else w's
// own, so a saved place on another screen stays on that screen.
static QString areaAtJs() {
    return QStringLiteral(
        "const areaAt = (w, x, y, gw, gh) => {\n"
        "  const cx = x + gw / 2, cy = y + gh / 2;\n"
        "  try {\n"
        "    for (const s of workspace.screens) {\n"
        "      const r = s.geometry;\n"
        "      if (cx >= r.x && cx < r.x + r.width && cy >= r.y && cy < r.y + r.height)\n"
        "        return workspace.clientArea(KWin.MaximizeArea, s, workspace.currentDesktop);\n"
        "    }\n"
        "  } catch (e) {}\n"
        "  try { return workspace.clientArea(KWin.MaximizeArea, w); } catch (e) {}\n"
        "  return w.output ? w.output.geometry : null;\n"
        "};\n");
}

bool WindowController::applyMainPosition(int x, int y, bool maximize) {
    if (!kwinAvailable_) return false;
    // A saved position can land off the current screen: a different display
    // scale, a monitor unplugged, or the window parked at an edge. KWin
    // places it there without complaint and the window then sits in the
    // taskbar drawing nothing. Clamp into the work area before applying.
    return runKwinScript(findWindowsPrelude() + areaAtJs() + QStringLiteral(
        "if (main) {\n"
        "  const g = main.frameGeometry;\n"
        "  let nx = %1 * k, ny = %2 * k;\n"
        "  const a = areaAt(main, nx, ny, g.width, g.height);\n"
        "  if (a && a.width > 0 && a.height > 0) {\n"
        "    nx = Math.max(a.x, Math.min(nx, a.x + a.width - g.width));\n"
        "    ny = Math.max(a.y, Math.min(ny, a.y + a.height - g.height));\n"
        "  }\n"
        "  main.frameGeometry = { x: nx, y: ny, width: g.width, height: g.height };\n"
        "  if (%3) main.setMaximize(true, true);\n"
        "}\n").arg(x).arg(y).arg(maximize ? QStringLiteral("true") : QStringLiteral("false")));
}

bool WindowController::applyMiniGeometry(int x, int y, int w, int h) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + areaAtJs() + QStringLiteral(
        "if (mini) {\n"
        "  const gw = %3 * k, gh = %4 * k;\n"
        "  let nx = %1 * k, ny = %2 * k;\n"
        "  const a = areaAt(mini, nx, ny, gw, gh);\n"
        "  if (a && a.width > 0 && a.height > 0) {\n"
        "    nx = Math.max(a.x, Math.min(nx, a.x + a.width - gw));\n"
        "    ny = Math.max(a.y, Math.min(ny, a.y + a.height - gh));\n"
        "  }\n"
        "  mini.frameGeometry = { x: nx, y: ny, width: gw, height: gh };\n"
        "}\n").arg(x).arg(y).arg(w).arg(h));
}

bool WindowController::applyMainGeometry(int x, int y, int w, int h) {
    if (!kwinAvailable_) return false;
    return runKwinScript(findWindowsPrelude() + QStringLiteral(
        "if (main) main.frameGeometry = { x: %1 * k, y: %2 * k, width: %3 * k, height: %4 * k };\n")
        .arg(x).arg(y).arg(w).arg(h));
}
