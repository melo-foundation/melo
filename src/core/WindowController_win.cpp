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
bool WindowController::alignForExpand(int, int) { return false; }
bool WindowController::setWindowOpacities(const QVariantList&) { return false; }
// false: the caller's own QWindow::setPosition already performed the move on
// this platform (only Wayland needs the compositor to do it).
bool WindowController::moveWindows(const QVariantList&) { return false; }
bool WindowController::setKeepAbove(bool) { return false; }
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
bool WindowController::applyMainPosition(int, int) { return false; }
bool WindowController::applyMainGeometry(int, int, int, int) { return false; }
