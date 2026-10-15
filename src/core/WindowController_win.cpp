// Windows backend for WindowController: a compile-only stub. Every op is a
// safe no-op; kwinAvailable() is false,
// so QML uses its non-KWin fallbacks (client-side opacity swap, no blur).
#include "WindowController.h"
#include <QGuiApplication>
#include <QQuickWindow>

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

WindowController::WindowController(QObject* parent) : QObject(parent) { initFocusTracking(); }
WindowController::~WindowController() = default;

void WindowController::setInputEnabled(QQuickWindow*, bool) {}
void WindowController::setBlurBehind(QQuickWindow*, bool) {}
void WindowController::setBlurRegion(QQuickWindow*, int, int, int, int) {}
void WindowController::setBackgroundContrast(QQuickWindow*, bool, double, double, double,
                                             const QColor&) {}
bool WindowController::blurAvailable() const { return false; }
bool WindowController::contrastAvailable() const { return false; }
void WindowController::setInputRegion(QQuickWindow*, int, int, int, int) {}
bool WindowController::alignForCollapse(int) { return false; }
bool WindowController::alignForExpand(int, int, int) { return false; }
bool WindowController::fitPopupHost(const QString&) { return false; }
void WindowController::restackBelow(QQuickWindow*, QQuickWindow*) {}
QString WindowController::stackOrder(QQuickWindow*, QQuickWindow*) { return QString(); }
void WindowController::keepBufferInStep(QQuickWindow*) {}
void WindowController::startSystemMove(QQuickWindow* win, QQuickWindow*) { if (win) win->startSystemMove(); }
void WindowController::startSystemResize(QQuickWindow* win, int edges, QQuickWindow*) {
    if (win) win->startSystemResize(Qt::Edges(edges));
}
bool WindowController::setWindowKeepAbove(QQuickWindow* win, bool on) {
    if (!win) return false;
    win->setFlag(Qt::WindowStaysOnTopHint, on);
    return true;
}
bool WindowController::placePopupWindowOverMain(const QString&, int, int) { return false; }
bool WindowController::watchPopupWindows(bool, bool) { return false; }
bool WindowController::placePopupWindowBeside(const QString&) { return false; }
bool WindowController::raisePopupWindow(const QString&) { return false; }
bool WindowController::swapPopupWindows(const QString&, const QString&) { return false; }
bool WindowController::setWindowOpacities(const QVariantList&) { return false; }
// false: the caller's own QWindow::setPosition already performed the move on
// this platform (only Wayland needs the compositor to do it).
bool WindowController::moveWindows(const QVariantList&) { return false; }
bool WindowController::setKeepAbove(bool) { return false; }
// pinMode stays "none": the pin controls are hidden here.
bool WindowController::showWindowMenu(QQuickWindow*, int, int) { return false; }
bool WindowController::setMiniQueueGlue(bool) { return false; }
bool WindowController::setPluginWindowGlue(const QVariantList&) { return false; }
void WindowController::watchMainGeometry() {}
// false: nothing to watch FOR. A user drag on this platform arrives as
// QWindow::xChanged/yChanged, which is where the plugin window host already
// picks it up — the compositor-side watcher exists only because Wayland has no
// such event.
bool WindowController::watchWindowGeometry(const QStringList&) { return false; }
// false: callers fall back to the client-side position, which IS authoritative
// on this platform (only Wayland hides a window's position from its client).
bool WindowController::reportMainGeometry() { return false; }
bool WindowController::applyMainPosition(int, int, bool) { return false; }
bool WindowController::applyMiniGeometry(int, int, int, int) { return false; }
bool WindowController::applyMainGeometry(int, int, int, int) { return false; }
