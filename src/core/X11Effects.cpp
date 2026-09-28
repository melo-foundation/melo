#include "X11Effects.h"
#include "BlurSupport.h"

#include <QCoreApplication>
#include <QDynamicPropertyChangeEvent>
#include <QEvent>
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QWindow>

#include <xcb/shape.h>
#include <xcb/xcb.h>
#include <cstdlib>
#include <vector>

namespace {

xcb_connection_t* connection() {
#if QT_CONFIG(xcb)
    if (QGuiApplication::platformName() != QLatin1String("xcb")) return nullptr;
    auto* x11 = qGuiApp ? qGuiApp->nativeInterface<QNativeInterface::QX11Application>() : nullptr;
    return x11 ? x11->connection() : nullptr;
#else
    return nullptr;   // a Qt built without xcb
#endif
}

}  // namespace

X11Blur* X11Blur::instance() {
    static X11Blur* self = nullptr;
    static bool tried = false;
    if (!tried) {
        tried = true;
        if (connection()) self = new X11Blur();
    }
    return self;
}

X11Blur::X11Blur() : QObject(qGuiApp) {
    xcb_connection_t* c = connection();
    root_ = xcb_setup_roots_iterator(xcb_get_setup(c)).data->root;
    static const char name[] = "_KDE_NET_WM_BLUR_BEHIND_REGION";
    xcb_intern_atom_reply_t* a = xcb_intern_atom_reply(
        c, xcb_intern_atom(c, false, sizeof(name) - 1, name), nullptr);
    if (a) { atom_ = a->atom; std::free(a); }

    // Event masks are per client, and Qt already selects on the root: add
    // PropertyChange to Qt's mask, never replace it.
    xcb_get_window_attributes_reply_t* attr = xcb_get_window_attributes_reply(
        c, xcb_get_window_attributes(c, root_), nullptr);
    const quint32 mask = (attr ? attr->your_event_mask : 0) | XCB_EVENT_MASK_PROPERTY_CHANGE;
    std::free(attr);
    xcb_change_window_attributes(c, root_, XCB_CW_EVENT_MASK, &mask);
    xcb_flush(c);

    available_ = readAvailable();
    QCoreApplication::instance()->installNativeEventFilter(this);
}

bool X11Blur::readAvailable() const {
    xcb_connection_t* c = connection();
    if (!c || !atom_) return false;
    xcb_list_properties_reply_t* r = xcb_list_properties_reply(
        c, xcb_list_properties(c, root_), nullptr);
    if (!r) return false;
    const xcb_atom_t* atoms = xcb_list_properties_atoms(r);
    const int n = xcb_list_properties_atoms_length(r);
    bool found = false;
    for (int i = 0; i < n && !found; ++i) found = atoms[i] == atom_;
    std::free(r);
    return found;
}

bool X11Blur::nativeEventFilter(const QByteArray& type, void* message, qintptr*) {
    if (type != "xcb_generic_event_t" || !message) return false;
    auto* ev = static_cast<xcb_generic_event_t*>(message);
    if ((ev->response_type & ~0x80) != XCB_PROPERTY_NOTIFY) return false;
    auto* pn = reinterpret_cast<xcb_property_notify_event_t*>(ev);
    if (pn->window != root_ || pn->atom != atom_) return false;
    const bool now = pn->state == XCB_PROPERTY_NEW_VALUE;
    if (now != available_) {
        available_ = now;
        emit availabilityChanged();
    }
    return false;
}

void X11Blur::setBlur(QWindow* w, bool on, const QRegion& region, bool followShape) {
    if (!w) return;
    if (!states_.contains(w)) {
        w->installEventFilter(this);
        connect(w, &QObject::destroyed, this, [this, w] { states_.remove(w); });
    }
    State& s = states_[w];
    s.on = on;
    s.followShape = followShape;
    s.region = region;
    apply(w);
}

// Set even while the effect is off: KWin reads the property when the effect
// loads, so nothing has to be re-sent.
void X11Blur::apply(QWindow* w) {
    xcb_connection_t* c = connection();
    if (!c || !atom_ || !w->handle()) return;
    const State s = states_.value(w);
    const xcb_window_t wid = xcb_window_t(w->winId());
    if (!s.on) {
        xcb_delete_property(c, wid, atom_);
    } else {
        const QRegion r = s.followShape ? w->property("meloShape").value<QRegion>() : s.region;
        const QList<quint32> data = x11BlurCardinals(r, w->devicePixelRatio());
        xcb_change_property(c, XCB_PROP_MODE_REPLACE, wid, atom_, XCB_ATOM_CARDINAL, 32,
                            quint32(data.size()), data.constData());
    }
    xcb_flush(c);
}

bool X11Blur::eventFilter(QObject* obj, QEvent* ev) {
    auto* w = qobject_cast<QWindow*>(obj);
    if (!w || !states_.contains(w)) return QObject::eventFilter(obj, ev);
    switch (ev->type()) {
    case QEvent::PlatformSurface:
        // a hide/show can give the window a new X window without the property
        if (static_cast<QPlatformSurfaceEvent*>(ev)->surfaceEventType()
            == QPlatformSurfaceEvent::SurfaceCreated)
            apply(w);
        break;
    case QEvent::DevicePixelRatioChange:
        apply(w);
        break;
    case QEvent::DynamicPropertyChange:
        if (states_.value(w).followShape
            && static_cast<QDynamicPropertyChangeEvent*>(ev)->propertyName() == "meloShape")
            apply(w);
        break;
    default:
        break;
    }
    return QObject::eventFilter(obj, ev);
}

namespace {

void applyInputShape(QWindow* w) {
    xcb_connection_t* c = connection();
    if (!c || !w->handle()) return;
    const xcb_window_t wid = xcb_window_t(w->winId());
    const QVariant want = w->property("meloX11Input");
    if (!want.isValid()) {
        xcb_shape_mask(c, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT, wid, 0, 0, XCB_NONE);
    } else {
        // the same outward rounding as the blur region
        const QList<quint32> q = x11BlurCardinals(want.value<QRegion>(), w->devicePixelRatio());
        std::vector<xcb_rectangle_t> rects;
        for (qsizetype i = 0; i + 3 < q.size(); i += 4)
            rects.push_back({qint16(qint32(q[i])), qint16(qint32(q[i + 1])),
                             quint16(q[i + 2]), quint16(q[i + 3])});
        // no rects = no input anywhere
        xcb_shape_rectangles(c, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT,
                             XCB_CLIP_ORDERING_UNSORTED, wid, 0, 0,
                             quint32(rects.size()), rects.data());
    }
    xcb_flush(c);
}

// A window asked before it has an X window, or given a new one by a
// hide/show, gets its input shape when the X window appears.
class InputShapeKeeper : public QObject {
public:
    using QObject::QObject;
    bool eventFilter(QObject* obj, QEvent* ev) override {
        if (ev->type() == QEvent::PlatformSurface
            && static_cast<QPlatformSurfaceEvent*>(ev)->surfaceEventType()
                   == QPlatformSurfaceEvent::SurfaceCreated)
            if (auto* w = qobject_cast<QWindow*>(obj)) applyInputShape(w);
        return QObject::eventFilter(obj, ev);
    }
};

}  // namespace

void x11SetInputShape(QWindow* w, const QRegion* region) {
    if (!w || !connection()) return;
    static InputShapeKeeper* keeper = new InputShapeKeeper(qGuiApp);
    if (!w->property("meloX11InputKept").toBool()) {
        w->setProperty("meloX11InputKept", true);
        w->installEventFilter(keeper);
    }
    w->setProperty("meloX11Input", region ? QVariant::fromValue(*region) : QVariant());
    applyInputShape(w);
}
