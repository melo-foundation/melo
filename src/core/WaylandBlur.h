#pragma once
#include <QObject>
#include <QRegion>
#include <QHash>

#include "BlurSupport.h"

class QWindow;
struct wl_display;
struct wl_event_queue;
struct wl_registry;
struct wl_compositor;
struct ext_background_effect_manager_v1;
struct ext_background_effect_surface_v1;
struct org_kde_kwin_blur_manager;
struct org_kde_kwin_contrast_manager;
struct org_kde_kwin_blur;
struct org_kde_kwin_contrast;

// Blur behind melo's windows, spoken directly over Wayland: no KF6
// WindowSystem to build or bundle, and it works against a static Qt (where
// KWindowEffects' plugin loading does not). ext-background-effect-v1 when the
// compositor has it, org_kde_kwin_blur + contrast otherwise (see BlurSupport).
//
// The globals are bound on a private queue with two roundtrips at init, so the
// first capabilities event is in before anyone asks. The registry and the
// managers then move to Qt's default queue, which Qt dispatches on the GUI
// thread: a later capabilities event (KWin toggling its Blur effect) or a KWin
// 6.6-or-older blur global coming and going arrives there and re-applies every
// window's stored state.
class WaylandBlur : public QObject {
    Q_OBJECT
public:
    // null when not on wayland or the display can't be reached
    static WaylandBlur* instance();

    bool available() const { return support_.blur(); }
    bool contrastAvailable() const { return support_.contrast() && contrastMgr_; }
    BlurSupport::Path path() const { return support_.path(); }

    // on=false removes the effect. An empty region is the whole window.
    // followShape: the region is the window's "meloShape" property
    // (WindowShapeItem) and is re-sent whenever that property changes.
    void setBlur(QWindow* w, bool on, const QRegion& region, bool followShape = false);
    // KDE path only.
    void setContrast(QWindow* w, bool on, double contrast, double saturation,
                     const QRegion& region);

    // C listener plumbing (public for the C callbacks)
    void global_(quint32 name, const char* iface, quint32 version);
    void globalRemove_(quint32 name);
    void capabilities_(quint32 flags);

signals:
    // available() or contrastAvailable() changed
    void availabilityChanged();

protected:
    // Qt destroys and recreates wl_surfaces on hide/show, and an effect object
    // created for the old surface silently applies to nothing. Track surface
    // lifecycle per window and re-apply the stored state on the fresh surface.
    // Also follows "meloShape" for followShape windows.
    bool eventFilter(QObject* obj, QEvent* ev) override;

private:
    WaylandBlur();
    struct wl_surface* surfaceFor(QWindow* w) const;
    void dropHandles(QWindow* w);
    void track(QWindow* w);
    void applyBlur(QWindow* w);
    void applyContrast(QWindow* w);
    // re-sends every window's state after the path or a capability changed
    void reapplyAll();
    // emits availabilityChanged and re-applies when `before` differs
    void supportChanged(const BlurSupport& before, bool contrastBefore);
    void debug(const char* fmt, ...) const;

    struct State {
        bool applied = false;   // blur state sent to the current surface
        bool blurOn = false;
        bool followShape = false;
        QRegion blurRegion;
        bool contrastOn = false;
        double contrast = 1, saturation = 1;
        QRegion contrastRegion;
    };
    QHash<QWindow*, State> states_;

    wl_display* display_ = nullptr;
    wl_event_queue* queue_ = nullptr;
    wl_registry* registry_ = nullptr;
    wl_compositor* compositor_ = nullptr;
    ext_background_effect_manager_v1* extMgr_ = nullptr;
    org_kde_kwin_blur_manager* blurMgr_ = nullptr;
    org_kde_kwin_contrast_manager* contrastMgr_ = nullptr;
    // registry names, for global_remove
    quint32 extName_ = 0, blurName_ = 0, contrastName_ = 0;
    BlurSupport support_;

    // live effect objects per window. ext allows one per wl_surface for the
    // surface's lifetime (a second get_background_effect is a fatal protocol
    // error), so that one is kept and re-used, never replaced.
    QHash<QWindow*, ext_background_effect_surface_v1*> exts_;
    QHash<QWindow*, org_kde_kwin_blur*> blurs_;
    QHash<QWindow*, org_kde_kwin_contrast*> contrasts_;
};
