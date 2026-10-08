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
#include <cstring>
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

bool x11StartSystemResize(QWindow* w, Qt::Edges edges) {
    xcb_connection_t* c = connection();
    if (!w || !c || !w->handle()) return false;
    static const struct { Qt::Edges e; quint32 dir; } dirs[] = {
        {Qt::TopEdge | Qt::LeftEdge, 0}, {Qt::TopEdge, 1}, {Qt::TopEdge | Qt::RightEdge, 2},
        {Qt::RightEdge, 3}, {Qt::RightEdge | Qt::BottomEdge, 4}, {Qt::BottomEdge, 5},
        {Qt::BottomEdge | Qt::LeftEdge, 6}, {Qt::LeftEdge, 7}};
    quint32 dir = 99;
    for (const auto& d : dirs) if (d.e == edges) dir = d.dir;
    if (edges == Qt::Edges()) dir = 8;   // _NET_WM_MOVERESIZE_MOVE
    if (dir == 99) return false;
    const xcb_window_t win = xcb_window_t(w->winId());
    xcb_query_pointer_reply_t* p = xcb_query_pointer_reply(c, xcb_query_pointer(c, win), nullptr);
    if (!p) return false;
    static const char name[] = "_NET_WM_MOVERESIZE";
    xcb_intern_atom_reply_t* a = xcb_intern_atom_reply(
        c, xcb_intern_atom(c, false, sizeof(name) - 1, name), nullptr);
    if (!a) { std::free(p); return false; }
    xcb_client_message_event_t ev{};
    ev.response_type = XCB_CLIENT_MESSAGE;
    ev.format = 32;
    ev.window = win;
    ev.type = a->atom;
    ev.data.data32[0] = quint32(p->root_x);
    ev.data.data32[1] = quint32(p->root_y);
    ev.data.data32[2] = dir;
    ev.data.data32[3] = XCB_BUTTON_INDEX_1;
    const xcb_window_t root = p->root;
    std::free(a);
    std::free(p);
    xcb_ungrab_pointer(c, XCB_CURRENT_TIME);
    xcb_send_event(c, false, root,
                   XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
                   reinterpret_cast<const char*>(&ev));
    xcb_flush(c);
    return true;
}

namespace {
xcb_atom_t internAtom(xcb_connection_t* c, const char* name) {
    xcb_intern_atom_reply_t* a = xcb_intern_atom_reply(
        c, xcb_intern_atom(c, false, quint16(std::strlen(name)), name), nullptr);
    const xcb_atom_t r = a ? a->atom : XCB_ATOM_NONE;
    std::free(a);
    return r;
}
xcb_window_t rootOf(xcb_connection_t* c) { return xcb_setup_roots_iterator(xcb_get_setup(c)).data->root; }
}  // namespace

QString x11StackOrder(const QList<QWindow*>& windows) {
    xcb_connection_t* c = connection();
    if (!c) return QString();
    xcb_get_property_reply_t* p = xcb_get_property_reply(c,
        xcb_get_property(c, false, rootOf(c), internAtom(c, "_NET_CLIENT_LIST_STACKING"),
                         XCB_ATOM_WINDOW, 0, 4096), nullptr);
    if (!p) return QString();
    const auto* ids = static_cast<const xcb_window_t*>(xcb_get_property_value(p));
    const int n = xcb_get_property_value_length(p) / int(sizeof(xcb_window_t));
    QString out = QStringLiteral("of %1:").arg(n);
    for (QWindow* w : windows) {
        if (!w || !w->handle()) continue;
        int at = -1;
        for (int i = 0; i < n; ++i) if (ids[i] == xcb_window_t(w->winId())) at = i;
        out += QStringLiteral(" %1@%2").arg(w->title()).arg(at);
    }
    std::free(p);
    return out;
}

bool x11RestackBelow(QWindow* w, QWindow* sibling) {
    xcb_connection_t* c = connection();
    if (!c || !w || !sibling || !w->handle() || !sibling->handle()) return false;
    xcb_client_message_event_t ev{};
    ev.response_type = XCB_CLIENT_MESSAGE;
    ev.format = 32;
    ev.window = xcb_window_t(w->winId());
    ev.type = internAtom(c, "_NET_RESTACK_WINDOW");
    ev.data.data32[0] = 2;   // a pager's request: KWin applies it without focus-stealing checks
    ev.data.data32[1] = xcb_window_t(sibling->winId());
    ev.data.data32[2] = XCB_STACK_MODE_BELOW;
    xcb_send_event(c, false, rootOf(c),
                   XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
                   reinterpret_cast<const char*>(&ev));
    xcb_flush(c);
    return true;
}
