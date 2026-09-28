#pragma once
#include <QAbstractNativeEventFilter>
#include <QHash>
#include <QObject>
#include <QRegion>

class QWindow;

// Blur behind melo's windows for X11 clients of KWin (Plasma X11, or XWayland
// under Plasma Wayland): the _KDE_NET_WM_BLUR_BEHIND_REGION window property.
// KWin's Blur effect reads it while loaded and advertises itself by keeping a
// root-window property of the same name, the check KWindowEffects makes.
// A PropertyNotify on the root tracks the effect being switched on or off.
class X11Blur : public QObject, public QAbstractNativeEventFilter {
    Q_OBJECT
public:
    // null when not on xcb
    static X11Blur* instance();

    bool available() const { return available_; }
    // on=false deletes the property. An empty region is the whole window.
    // followShape: the region is the window's "meloShape" property, re-sent
    // whenever that changes. Kept per window and re-sent on a new X window.
    void setBlur(QWindow* w, bool on, const QRegion& region, bool followShape = false);

    bool nativeEventFilter(const QByteArray& type, void* message, qintptr* result) override;

signals:
    void availabilityChanged();

protected:
    bool eventFilter(QObject* obj, QEvent* ev) override;

private:
    X11Blur();
    bool readAvailable() const;
    void apply(QWindow* w);

    struct State {
        bool on = false;
        bool followShape = false;
        QRegion region;
    };
    QHash<QWindow*, State> states_;
    quint32 root_ = 0;
    quint32 atom_ = 0;
    bool available_ = false;
};

// X11 input shape, leaving the bounding shape (QWindow::setMask) to draw the
// window. null region = input everywhere the window is drawn. Kept on the
// window and re-sent whenever Qt creates its X window. No-op off xcb.
void x11SetInputShape(QWindow* w, const QRegion* region);
