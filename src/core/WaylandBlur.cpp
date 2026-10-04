#include "WaylandBlur.h"

#include <QEvent>
#include <QDynamicPropertyChangeEvent>
#include <QtGlobal>
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>
#include <cstdarg>
#include <cstdio>
#include "ext-background-effect-v1-client-protocol.h"
#include "blur-client-protocol.h"
#include "contrast-client-protocol.h"

static void registryGlobal(void* data, wl_registry*, uint32_t name,
                           const char* interface, uint32_t version) {
    static_cast<WaylandBlur*>(data)->global_(name, interface, version);
}
static void registryGlobalRemove(void* data, wl_registry*, uint32_t name) {
    static_cast<WaylandBlur*>(data)->globalRemove_(name);
}
static const wl_registry_listener kRegistryListener = {
    registryGlobal, registryGlobalRemove
};

static void extCapabilities(void* data, ext_background_effect_manager_v1*, uint32_t flags) {
    static_cast<WaylandBlur*>(data)->capabilities_(flags);
}
static const ext_background_effect_manager_v1_listener kExtListener = {
    extCapabilities
};

static const char* pathName(BlurSupport::Path p) {
    switch (p) {
    case BlurSupport::Path::Ext: return "ext";
    case BlurSupport::Path::Kde: return "kde";
    case BlurSupport::Path::None: return "none";
    }
    return "none";
}

void WaylandBlur::debug(const char* fmt, ...) const {
    static const bool on = qEnvironmentVariableIsSet("MELO_BLUR_DEBUG");
    if (!on) return;
    std::fputs("[blur] ", stderr);
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
    std::fputc('\n', stderr);
}

WaylandBlur* WaylandBlur::instance() {
    static WaylandBlur* inst = [] () -> WaylandBlur* {
        if (!QGuiApplication::platformName().contains(QLatin1String("wayland")))
            return nullptr;
        auto* b = new WaylandBlur();
        return b->display_ ? b : nullptr;
    }();
    return inst;
}

WaylandBlur::WaylandBlur() {
    auto* ni = QGuiApplication::platformNativeInterface();
    if (!ni) return;
    display_ = static_cast<wl_display*>(ni->nativeResourceForIntegration("wl_display"));
    if (!display_) return;
    // Private queue for the startup roundtrips, so waiting on them never
    // dispatches Qt's own objects. The first roundtrip binds the globals; the
    // second collects what binding them sent (ext's first capabilities).
    queue_ = wl_display_create_queue(display_);
    registry_ = wl_display_get_registry(display_);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry_), queue_);
    wl_registry_add_listener(registry_, &kRegistryListener, this);
    wl_display_roundtrip_queue(display_, queue_);
    wl_display_roundtrip_queue(display_, queue_);
    // Everything that can still receive events moves to the default queue,
    // which Qt dispatches on the GUI thread. Proxies created from these later
    // inherit it.
    const auto toDefault = [](void* p) {
        if (p) wl_proxy_set_queue(static_cast<wl_proxy*>(p), nullptr);
    };
    toDefault(registry_);
    toDefault(compositor_);
    toDefault(extMgr_);
    toDefault(blurMgr_);
    toDefault(contrastMgr_);
    // anything Qt's reader thread queued here before the move
    wl_display_dispatch_queue_pending(display_, queue_);
    debug("path %s  blur %s  contrast %s", pathName(support_.path()),
          support_.blur() ? "yes" : "no", contrastAvailable() ? "yes" : "no");
}

void WaylandBlur::global_(quint32 name, const char* iface, quint32 /*version*/) {
    const QLatin1String i(iface);
    const BlurSupport before = support_;
    const bool contrastBefore = contrastAvailable();
    if (i == QLatin1String("ext_background_effect_manager_v1")) {
        if (extMgr_) return;
        extName_ = name;
        extMgr_ = static_cast<ext_background_effect_manager_v1*>(
            wl_registry_bind(registry_, name, &ext_background_effect_manager_v1_interface, 1));
        ext_background_effect_manager_v1_add_listener(extMgr_, &kExtListener, this);
        support_.extBound = true;
        debug("ext_background_effect_manager_v1 bound");
    } else if (i == QLatin1String("org_kde_kwin_blur_manager")) {
        if (blurMgr_) return;
        blurName_ = name;
        blurMgr_ = static_cast<org_kde_kwin_blur_manager*>(
            wl_registry_bind(registry_, name, &org_kde_kwin_blur_manager_interface, 1));
        support_.kdeBlur = true;
        debug("org_kde_kwin_blur_manager bound");
    } else if (i == QLatin1String("org_kde_kwin_contrast_manager")) {
        if (contrastMgr_) return;
        contrastName_ = name;
        contrastMgr_ = static_cast<org_kde_kwin_contrast_manager*>(
            wl_registry_bind(registry_, name, &org_kde_kwin_contrast_manager_interface, 1));
        support_.kdeContrast = true;
        debug("org_kde_kwin_contrast_manager bound");
    } else if (i == QLatin1String("wl_compositor")) {
        if (!compositor_)
            compositor_ = static_cast<wl_compositor*>(
                wl_registry_bind(registry_, name, &wl_compositor_interface, 1));
        return;
    } else {
        return;
    }
    supportChanged(before, contrastBefore);
}

// KWin 6.6 and older remove the blur and contrast globals a second after the
// Blur effect unloads, and announce new ones under new names when it loads.
// KWin 6.7 keeps the ext global and changes the capability instead.
void WaylandBlur::globalRemove_(quint32 name) {
    const BlurSupport before = support_;
    const bool contrastBefore = contrastAvailable();
    if (extMgr_ && name == extName_) {
        for (auto* e : std::as_const(exts_)) ext_background_effect_surface_v1_destroy(e);
        exts_.clear();
        ext_background_effect_manager_v1_destroy(extMgr_);
        extMgr_ = nullptr;
        support_.extBound = false;
        support_.extBlurCap = false;
        debug("ext_background_effect_manager_v1 removed");
    } else if (blurMgr_ && name == blurName_) {
        for (auto* b : std::as_const(blurs_)) org_kde_kwin_blur_release(b);
        blurs_.clear();
        org_kde_kwin_blur_manager_destroy(blurMgr_);
        blurMgr_ = nullptr;
        support_.kdeBlur = false;
        debug("org_kde_kwin_blur_manager removed");
    } else if (contrastMgr_ && name == contrastName_) {
        for (auto* c : std::as_const(contrasts_)) org_kde_kwin_contrast_release(c);
        contrasts_.clear();
        org_kde_kwin_contrast_manager_destroy(contrastMgr_);
        contrastMgr_ = nullptr;
        support_.kdeContrast = false;
        debug("org_kde_kwin_contrast_manager removed");
    } else {
        return;
    }
    wl_display_flush(display_);
    supportChanged(before, contrastBefore);
}

void WaylandBlur::capabilities_(quint32 flags) {
    const BlurSupport before = support_;
    const bool contrastBefore = contrastAvailable();
    support_.extBlurCap = flags & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR;
    debug("ext capabilities 0x%x (blur %s)", flags, support_.extBlurCap ? "yes" : "no");
    supportChanged(before, contrastBefore);
}

void WaylandBlur::supportChanged(const BlurSupport& before, bool contrastBefore) {
    if (support_ == before && contrastAvailable() == contrastBefore) return;
    reapplyAll();
    emit availabilityChanged();
}

void WaylandBlur::reapplyAll() {
    for (auto it = states_.cbegin(); it != states_.cend(); ++it) {
        QWindow* w = it.key();
        if (it->blurOn || exts_.contains(w) || blurs_.contains(w)) applyBlur(w);
        if (it->contrastOn || contrasts_.contains(w)) applyContrast(w);
    }
}

wl_surface* WaylandBlur::surfaceFor(QWindow* w) const {
    auto* ni = QGuiApplication::platformNativeInterface();
    if (!ni || !w) return nullptr;
    return static_cast<wl_surface*>(ni->nativeResourceForWindow("surface", w));
}

static wl_region* makeRegion(wl_compositor* comp, const QRegion& region) {
    if (!comp || region.isEmpty()) return nullptr;
    wl_region* r = wl_compositor_create_region(comp);
    for (const QRect& rect : region)
        wl_region_add(r, rect.x(), rect.y(), rect.width(), rect.height());
    return r;
}

void WaylandBlur::setBlur(QWindow* w, bool on, const QRegion& region, bool followShape) {
    if (!w) return;
    track(w);
    State& st = states_[w];
    // Already on the surface. Re-sending makes the window draw a frame, and a
    // hidden window drawing on every step of another window's resize makes
    // that resize jitter.
    if (st.applied && st.blurOn == on && st.followShape == followShape && st.blurRegion == region)
        return;
    st.blurOn = on;
    st.followShape = followShape;
    st.blurRegion = region;
    applyBlur(w);
}

void WaylandBlur::applyBlur(QWindow* w) {
    wl_surface* surface = surfaceFor(w);
    if (!surface) return;
    states_[w].applied = true;
    const State st = states_.value(w);
    const BlurSupport::Path path = support_.path();
    bool sent = false;

    // the path not in use keeps nothing on this surface
    if (path != BlurSupport::Path::Ext) {
        if (auto* e = exts_.take(w)) { ext_background_effect_surface_v1_destroy(e); sent = true; }
    }
    if (path != BlurSupport::Path::Kde) {
        if (auto* b = blurs_.take(w)) {
            org_kde_kwin_blur_release(b);
            if (blurMgr_) org_kde_kwin_blur_manager_unset(blurMgr_, surface);
            sent = true;
        }
    }

    if (path == BlurSupport::Path::Ext) {
        ext_background_effect_surface_v1* e = exts_.value(w);
        // Created only when there is blur to show; once it exists it stays
        // for the surface's lifetime and "off" is a null region on it.
        if (!e && st.blurOn && support_.extBlurCap) {
            e = ext_background_effect_manager_v1_get_background_effect(extMgr_, surface);
            exts_.insert(w, e);
        }
        if (e) {
            wl_region* r = st.blurOn ? makeRegion(compositor_, extBlurRegion(st.blurRegion))
                                     : nullptr;
            ext_background_effect_surface_v1_set_blur_region(e, r);
            if (r) wl_region_destroy(r);
            sent = true;
        }
    } else if (path == BlurSupport::Path::Kde) {
        if (!st.blurOn) {
            if (auto* b = blurs_.take(w)) org_kde_kwin_blur_release(b);
            org_kde_kwin_blur_manager_unset(blurMgr_, surface);
            sent = true;
        } else {
            org_kde_kwin_blur* b = blurs_.value(w);
            if (!b) {
                b = org_kde_kwin_blur_manager_create(blurMgr_, surface);
                blurs_.insert(w, b);
            }
            wl_region* r = makeRegion(compositor_, st.blurRegion);
            org_kde_kwin_blur_set_region(b, r);   // null region = whole surface
            org_kde_kwin_blur_commit(b);
            if (r) wl_region_destroy(r);
            sent = true;
        }
    }
    if (!sent) return;
    wl_display_flush(display_);
    // Both protocols stage their state until the surface's next commit, which
    // Qt makes on the next frame. Without a repaint the new value sits unseen
    // until something else redraws the window.
    w->requestUpdate();

    // flags a region that does not match the window's size
    const QRect rb = st.blurRegion.boundingRect();
    debug("%s %s on %p  window %dx%d  region %dx%d+%d+%d (%d rects)%s%s",
          pathName(path), st.blurOn ? "set" : "off", static_cast<void*>(w),
          w->width(), w->height(), rb.width(), rb.height(), rb.x(), rb.y(),
          int(st.blurRegion.rectCount()),
          st.blurRegion.isEmpty() ? "  WHOLE SURFACE"
          : (rb.width() != w->width() || rb.height() != w->height()) ? "  MISMATCH" : "",
          path == BlurSupport::Path::Ext && !support_.extBlurCap ? "  (no blur capability)" : "");
}

void WaylandBlur::setContrast(QWindow* w, bool on, double contrast, double saturation,
                              const QRegion& region) {
    if (!w) return;
    track(w);
    State& st = states_[w];
    st.contrastOn = on; st.contrast = contrast;
    st.saturation = saturation; st.contrastRegion = region;
    applyContrast(w);
}

void WaylandBlur::applyContrast(QWindow* w) {
    wl_surface* surface = surfaceFor(w);
    if (!surface) return;
    const State st = states_.value(w);
    // ext has no contrast; a KDE contrast object must not ride along with it
    if (!support_.contrast() || !contrastMgr_) {
        if (auto* c = contrasts_.take(w)) {
            org_kde_kwin_contrast_release(c);
            if (contrastMgr_) org_kde_kwin_contrast_manager_unset(contrastMgr_, surface);
            wl_display_flush(display_);
            w->requestUpdate();
        }
        return;
    }
    if (!st.contrastOn) {
        if (auto* c = contrasts_.take(w)) org_kde_kwin_contrast_release(c);
        org_kde_kwin_contrast_manager_unset(contrastMgr_, surface);
        wl_display_flush(display_);
        w->requestUpdate();
        return;
    }
    // A fresh object every time: KWin latches state when the contrast object
    // is created, so re-sending values on it changes nothing on screen. One
    // object per change is a slider's worth of protocol traffic, off the frame path.
    if (auto* old = contrasts_.take(w)) org_kde_kwin_contrast_release(old);
    org_kde_kwin_contrast* c = org_kde_kwin_contrast_manager_create(contrastMgr_, surface);
    contrasts_.insert(w, c);
    wl_region* r = makeRegion(compositor_, st.contrastRegion);
    org_kde_kwin_contrast_set_region(c, r);
    org_kde_kwin_contrast_set_contrast(c, wl_fixed_from_double(st.contrast));
    // KWin 6.4 and older read intensity and leave it uninitialised if unsent
    org_kde_kwin_contrast_set_intensity(c, wl_fixed_from_double(1.0));
    org_kde_kwin_contrast_set_saturation(c, wl_fixed_from_double(st.saturation));
    org_kde_kwin_contrast_commit(c);
    if (r) wl_region_destroy(r);
    wl_display_flush(display_);
    w->requestUpdate();   // see applyBlur: the state applies on the next frame

    debug("contrast on %p c=%.2f s=%.2f", static_cast<void*>(w), st.contrast, st.saturation);
}

void WaylandBlur::track(QWindow* w) {
    if (!w || states_.contains(w)) return;
    states_.insert(w, State());
    w->installEventFilter(this);
    QObject::connect(w, &QWindow::destroyed, this, [this, w] {
        dropHandles(w);
        states_.remove(w);
    });
}

void WaylandBlur::dropHandles(QWindow* w) {
    // The wl_surface these were created for is going. ext's object must go
    // with it: the replacement surface gets a new one, and keeping the old
    // would leave a stale object in exts_.
    if (auto* e = exts_.take(w)) ext_background_effect_surface_v1_destroy(e);
    if (auto* b = blurs_.take(w)) org_kde_kwin_blur_release(b);
    if (auto* c = contrasts_.take(w)) org_kde_kwin_contrast_release(c);
    if (states_.contains(w)) states_[w].applied = false;
    if (display_) wl_display_flush(display_);
}

bool WaylandBlur::eventFilter(QObject* obj, QEvent* ev) {
    // A shaped window's region is cut again on every resize. Without this a
    // window that asked for blur once keeps the region of the size it had
    // then.
    if (ev->type() == QEvent::DynamicPropertyChange
            && static_cast<QDynamicPropertyChangeEvent*>(ev)->propertyName() == "meloShape") {
        auto* w = qobject_cast<QWindow*>(obj);
        auto it = w ? states_.find(w) : states_.end();
        if (it != states_.end() && it->followShape && it->blurOn) {
            const QRegion shape = w->property("meloShape").value<QRegion>();
            if (shape != it->blurRegion) {
                it->blurRegion = shape;
                applyBlur(w);
            }
        }
    } else if (ev->type() == QEvent::PlatformSurface) {
        auto* w = qobject_cast<QWindow*>(obj);
        auto* pse = static_cast<QPlatformSurfaceEvent*>(ev);
        if (w && states_.contains(w)) {
            if (pse->surfaceEventType()
                    == QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) {
                dropHandles(w);
            } else if (pse->surfaceEventType()
                           == QPlatformSurfaceEvent::SurfaceCreated) {
                const State st = states_.value(w);
                debug("surface recreated, reapplying");
                if (st.blurOn) applyBlur(w);
                if (st.contrastOn) applyContrast(w);
            }
        }
    }
    return QObject::eventFilter(obj, ev);
}
