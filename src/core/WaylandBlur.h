#pragma once
#include <QObject>
#include <QColor>
#include <QRegion>
#include <QHash>

class QWindow;
struct wl_display;
struct wl_event_queue;
struct wl_registry;
struct wl_compositor;
struct org_kde_kwin_blur_manager;
struct org_kde_kwin_contrast_manager;
struct org_kde_kwin_blur;
struct org_kde_kwin_contrast;

// KWin's blur / background-contrast Wayland protocols, spoken directly: no KF6
// WindowSystem to build or bundle, and it works against a static Qt (where
// KWindowEffects' plugin loading does not). Manager globals are bound on a
// private event queue (one roundtrip at init); requests are fire-and-forget.
// Non-KWin compositors lack the globals: available() is false, calls no-op.
class WaylandBlur : public QObject {
public:
    // null when not on wayland or the display can't be reached
    static WaylandBlur* instance();

    bool available() const { return blurMgr_ != nullptr; }
    bool contrastAvailable() const { return contrastMgr_ != nullptr; }

    // on=false removes the effect entirely (manager unset)
    void setBlur(QWindow* w, bool on, const QRegion& region);
    // `frost` is the surface's own background colour, sent as contrast v2's
    // frost (KWin stores it but no effect reads it; see setContrast). An
    // invalid or fully transparent colour unsets it.
    void setContrast(QWindow* w, bool on, double contrast, double intensity,
                     double saturation, const QRegion& region,
                     const QColor& frost = QColor());

    // registry callback plumbing (public for the C listener)
    void global_(quint32 name, const char* iface, quint32 version);

protected:
    // Qt destroys and recreates wl_surfaces on hide/show, and a blur object
    // created for the old surface silently applies to nothing. Track surface
    // lifecycle per window and re-apply the stored state on the fresh surface.
    bool eventFilter(QObject* obj, QEvent* ev) override;

private:
    WaylandBlur();
    struct wl_surface* surfaceFor(QWindow* w) const;
    void dropHandles(QWindow* w);
    void track(QWindow* w);

    struct State {
        bool blurOn = false;
        QRegion blurRegion;
        bool contrastOn = false;
        double contrast = 1, intensity = 1, saturation = 1;
        QRegion contrastRegion;
        QColor frost;
    };
    QHash<QWindow*, State> states_;

    wl_display* display_ = nullptr;
    wl_event_queue* queue_ = nullptr;
    wl_registry* registry_ = nullptr;
    wl_compositor* compositor_ = nullptr;
    org_kde_kwin_blur_manager* blurMgr_ = nullptr;
    org_kde_kwin_contrast_manager* contrastMgr_ = nullptr;
    quint32 contrastVer_ = 0;   // 2 = set_frost available

    // live effect objects per window, destroyed on unset
    QHash<QWindow*, org_kde_kwin_blur*> blurs_;
    QHash<QWindow*, org_kde_kwin_contrast*> contrasts_;
};
