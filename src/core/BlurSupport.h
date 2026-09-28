#pragma once
#include <QList>
#include <QRegion>
#include <climits>
#include <cmath>

// Which blur protocol WaylandBlur speaks, decided from the registry and the
// ext manager's capabilities event. Pure state, so a test can drive it
// without a compositor.
//
// ext-background-effect-v1 wins whenever its global is bound: KWin 6.7+,
// GNOME 51, niri, Hyprland 0.56, COSMIC. org_kde_kwin_blur (+ contrast) is used
// only without it (KWin 6.6 and older). One surface never gets both.
struct BlurSupport {
    enum class Path { None, Ext, Kde };

    bool extBound = false;     // ext_background_effect_manager_v1
    bool extBlurCap = false;   // its last capabilities event had the blur bit
    bool kdeBlur = false;      // org_kde_kwin_blur_manager
    bool kdeContrast = false;  // org_kde_kwin_contrast_manager

    Path path() const {
        if (extBound) return Path::Ext;
        if (kdeBlur) return Path::Kde;
        return Path::None;
    }
    // KWin keeps the ext global while the Blur effect is off and clears the
    // capability bit instead, so the global alone proves nothing.
    bool blur() const {
        switch (path()) {
        case Path::Ext: return extBlurCap;
        case Path::Kde: return true;
        case Path::None: return false;
        }
        return false;
    }
    // ext has no contrast or saturation. KWin 6.4 and older ran contrast as its
    // own effect, so the contrast global can be there without the blur one.
    bool contrast() const { return !extBound && kdeContrast; }

    bool operator==(const BlurSupport& o) const {
        return extBound == o.extBound && extBlurCap == o.extBlurCap
            && kdeBlur == o.kdeBlur && kdeContrast == o.kdeContrast;
    }
    bool operator!=(const BlurSupport& o) const { return !(*this == o); }
};

// The region sent with ext's set_blur_region. melo's empty region means the
// whole window, which org_kde_kwin_blur spells as a null region; on ext a null
// region removes the blur. The spec clips the region to the surface, so an
// oversized rect covers the window at any size and needs no re-send on resize.
// The same rect KWindowSystem sends; both ends stay inside int32.
inline QRegion extBlurRegion(const QRegion& region) {
    if (!region.isEmpty()) return region;
    return QRegion(INT_MIN / 2, INT_MIN / 2, INT_MAX, INT_MAX);
}

// _KDE_NET_WM_BLUR_BEHIND_REGION's value: x, y, w, h per rect, in the X
// window's device pixels. Empty means the whole window, which the property
// spells as a zero-length value. Edges round outward so scaled rects still meet.
inline QList<quint32> x11BlurCardinals(const QRegion& region, qreal dpr) {
    QList<quint32> out;
    if (dpr <= 0) dpr = 1;
    out.reserve(region.rectCount() * 4);
    for (const QRect& r : region) {
        const int x0 = int(std::floor(r.x() * dpr));
        const int y0 = int(std::floor(r.y() * dpr));
        const int x1 = int(std::ceil((r.x() + r.width()) * dpr));
        const int y1 = int(std::ceil((r.y() + r.height()) * dpr));
        out << quint32(x0) << quint32(y0) << quint32(x1 - x0) << quint32(y1 - y0);
    }
    return out;
}
