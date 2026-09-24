#include "WaylandBlur.h"

#include <QEvent>
#include <QtGlobal>
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>
#include <cstdio>
#include "blur-client-protocol.h"
#include "contrast-client-protocol.h"

static void registryGlobal(void* data, wl_registry*, uint32_t name,
                           const char* interface, uint32_t version) {
    static_cast<WaylandBlur*>(data)->global_(name, interface, version);
}
static void registryGlobalRemove(void*, wl_registry*, uint32_t) {}
static const wl_registry_listener kRegistryListener = {
    registryGlobal, registryGlobalRemove
};

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
    // private queue: our registry traffic never interleaves with Qt's
    queue_ = wl_display_create_queue(display_);
    registry_ = wl_display_get_registry(display_);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry_), queue_);
    wl_registry_add_listener(registry_, &kRegistryListener, this);
    wl_display_roundtrip_queue(display_, queue_);
}

void WaylandBlur::global_(quint32 name, const char* iface, quint32 version) {
    const QLatin1String i(iface);
    if (i == QLatin1String("org_kde_kwin_blur_manager")) {
        blurMgr_ = static_cast<org_kde_kwin_blur_manager*>(
            wl_registry_bind(registry_, name, &org_kde_kwin_blur_manager_interface, 1));
        if (qEnvironmentVariableIsSet("MELO_BLUR_DEBUG"))
        std::fprintf(stderr, "[blur] org_kde_kwin_blur_manager bound\n");
    }
    else if (i == QLatin1String("org_kde_kwin_contrast_manager")) {
        // v2 adds set_frost, which is the whole reason to ask for a version at
        // all here — bind as high as the compositor offers, up to what the
        // vendored protocol describes.
        contrastVer_ = qMin(version, 2u);
        contrastMgr_ = static_cast<org_kde_kwin_contrast_manager*>(
            wl_registry_bind(registry_, name, &org_kde_kwin_contrast_manager_interface,
                             contrastVer_));
        if (qEnvironmentVariableIsSet("MELO_BLUR_DEBUG"))
            std::fprintf(stderr, "[blur] org_kde_kwin_contrast_manager bound v%u (frost %s)\n",
                         contrastVer_, contrastVer_ >= 2 ? "yes" : "no");
    }
    else if (i == QLatin1String("wl_compositor"))
        compositor_ = static_cast<wl_compositor*>(
            wl_registry_bind(registry_, name, &wl_compositor_interface, 1));
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

void WaylandBlur::setBlur(QWindow* w, bool on, const QRegion& region) {
    if (!blurMgr_) return;
    track(w);
    states_[w].blurOn = on;
    states_[w].blurRegion = region;
    wl_surface* surface = surfaceFor(w);
    if (!surface) return;
    if (!on) {
        if (auto* b = blurs_.take(w)) org_kde_kwin_blur_release(b);
        org_kde_kwin_blur_manager_unset(blurMgr_, surface);
        wl_display_flush(display_);
        return;
    }
    org_kde_kwin_blur* b = blurs_.value(w);
    if (!b) {
        b = org_kde_kwin_blur_manager_create(blurMgr_, surface);
        blurs_.insert(w, b);
        QObject::connect(w, &QWindow::destroyed, qApp, [this, w] {
            blurs_.remove(w); contrasts_.remove(w);
        });
    }
    wl_region* r = makeRegion(compositor_, region);
    org_kde_kwin_blur_set_region(b, r);   // null region = whole surface
    org_kde_kwin_blur_commit(b);
    if (r) wl_region_destroy(r);
    wl_display_flush(display_);
    // Staged, not applied: org_kde_kwin_*_commit() only stages the state on
    // the object, and KWin reads it when the surface is next committed, on the
    // client's next frame. Without a repaint the new value sits unseen until
    // something else redraws the window.
    w->requestUpdate();

    // flags a region that does not match the window's size
    if (qEnvironmentVariableIsSet("MELO_BLUR_DEBUG")) {
        const QRect rb = region.boundingRect();
        std::fprintf(stderr,
                     "[blur] set on %p  window %dx%d  region %dx%d+%d+%d (%d rects)%s\n",
                     static_cast<void*>(w), w->width(), w->height(),
                     rb.width(), rb.height(), rb.x(), rb.y(), int(region.rectCount()),
                     region.isEmpty() ? "  WHOLE SURFACE" :
                     (rb.width() != w->width() || rb.height() != w->height())
                         ? "  MISMATCH" : "");
    }
}

// KWin ignores two of these arguments. intensity was read up to Plasma 6.4
// and dropped when 6.5 merged BackgroundContrast into blur (KWin MR !6838),
// whose colorTransformMatrix takes only saturation and contrast. frost is in
// protocol v2 and stored server-side (ContrastInterface::frost()), but no KWin
// effect has ever read it. Both are still sent: they are protocol arguments
// and another compositor may honour them. melo's settings expose contrast and
// saturation only.
void WaylandBlur::setContrast(QWindow* w, bool on, double contrast,
                              double intensity, double saturation,
                              const QRegion& region, const QColor& frost) {
    if (!contrastMgr_) return;
    track(w);
    State& st = states_[w];
    st.contrastOn = on; st.contrast = contrast; st.intensity = intensity;
    st.saturation = saturation; st.contrastRegion = region; st.frost = frost;
    wl_surface* surface = surfaceFor(w);
    if (!surface) return;
    if (!on) {
        if (auto* c = contrasts_.take(w)) org_kde_kwin_contrast_release(c);
        org_kde_kwin_contrast_manager_unset(contrastMgr_, surface);
        wl_display_flush(display_);
        return;
    }
    // A fresh object every time: KWin latches state when the contrast object
    // is created, so re-sending values on it changes nothing on screen. One
    // object per change is a slider's worth of protocol traffic, off the frame path.
    if (auto* old = contrasts_.take(w)) org_kde_kwin_contrast_release(old);
    org_kde_kwin_contrast* c = org_kde_kwin_contrast_manager_create(contrastMgr_, surface);
    contrasts_.insert(w, c);
    wl_region* r = makeRegion(compositor_, region);
    org_kde_kwin_contrast_set_region(c, r);
    org_kde_kwin_contrast_set_contrast(c, wl_fixed_from_double(contrast));
    org_kde_kwin_contrast_set_intensity(c, wl_fixed_from_double(intensity));
    org_kde_kwin_contrast_set_saturation(c, wl_fixed_from_double(saturation));
    if (contrastVer_ >= 2) {
        // a fully transparent colour is the caller saying "no frost"
        if (frost.isValid() && frost.alpha() > 0)
            org_kde_kwin_contrast_set_frost(c, frost.red(), frost.green(),
                                            frost.blue(), frost.alpha());
        else
            org_kde_kwin_contrast_unset_frost(c);
    }
    org_kde_kwin_contrast_commit(c);
    if (r) wl_region_destroy(r);
    wl_display_flush(display_);
    w->requestUpdate();   // see setBlur: the state applies on the next frame

    if (qEnvironmentVariableIsSet("MELO_BLUR_DEBUG"))
        std::fprintf(stderr,
                     "[blur] contrast on %p c=%.2f i=%.2f s=%.2f frost=%s\n",
                     static_cast<void*>(w), contrast, intensity, saturation,
                     (frost.isValid() && frost.alpha() > 0)
                         ? qPrintable(frost.name(QColor::HexArgb)) : "no");
}

void WaylandBlur::track(QWindow* w) {
    if (!w || states_.contains(w)) return;
    states_.insert(w, State());
    w->installEventFilter(this);
    QObject::connect(w, &QWindow::destroyed, this, [this, w] {
        states_.remove(w); blurs_.remove(w); contrasts_.remove(w);
    });
}

void WaylandBlur::dropHandles(QWindow* w) {
    // the wl_surface these were created for is gone — the protocol objects
    // are dead weight referencing nothing; release our side quietly
    if (auto* b = blurs_.take(w)) org_kde_kwin_blur_release(b);
    if (auto* c = contrasts_.take(w)) org_kde_kwin_contrast_release(c);
}

bool WaylandBlur::eventFilter(QObject* obj, QEvent* ev) {
    if (ev->type() == QEvent::PlatformSurface) {
        auto* w = qobject_cast<QWindow*>(obj);
        auto* pse = static_cast<QPlatformSurfaceEvent*>(ev);
        if (w && states_.contains(w)) {
            if (pse->surfaceEventType()
                    == QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) {
                dropHandles(w);
            } else if (pse->surfaceEventType()
                           == QPlatformSurfaceEvent::SurfaceCreated) {
                const State st = states_.value(w);
                if (qEnvironmentVariableIsSet("MELO_BLUR_DEBUG"))
                    std::fprintf(stderr, "[blur] surface recreated — reapplying\n");
                if (st.blurOn) setBlur(w, true, st.blurRegion);
                if (st.contrastOn)
                    setContrast(w, true, st.contrast, st.intensity,
                                st.saturation, st.contrastRegion, st.frost);
            }
        }
    }
    return QObject::eventFilter(obj, ev);
}
