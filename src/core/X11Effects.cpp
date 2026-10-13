#include "X11Effects.h"
#include "BlurSupport.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDynamicPropertyChangeEvent>
#include <QEvent>
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QWindow>
#include <QElapsedTimer>
#include <QTimer>
#include <QQuickWindow>

#include <xcb/shape.h>
#include <xcb/xcb.h>
#include <xcb/sync.h>
#include <xcb/present.h>
#include <algorithm>
#include <cstdio>
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

namespace {
// MELO_GEOM_DEBUG on X11: each _NET_WM_SYNC_REQUEST and ConfigureNotify a melo window
// receives, with wall-clock ms, to line up with the frame log's swaps
class SyncTrace : public QAbstractNativeEventFilter {
public:
    explicit SyncTrace(xcb_connection_t* c)
        : protocols_(internAtom(c, "WM_PROTOCOLS")), sync_(internAtom(c, "_NET_WM_SYNC_REQUEST")) {}
    bool nativeEventFilter(const QByteArray& type, void* message, qintptr*) override {
        if (type != "xcb_generic_event_t") return false;
        auto* ev = static_cast<xcb_generic_event_t*>(message);
        const uint8_t kind = ev->response_type & 0x7f;
        if (kind == XCB_CLIENT_MESSAGE) {
            auto* cm = reinterpret_cast<xcb_client_message_event_t*>(ev);
            if (cm->type == protocols_ && cm->data.data32[0] == sync_)
                std::fprintf(stderr, "[xsync] %lld %s value %u\n", now(), name(cm->window).constData(),
                             cm->data.data32[2]);
        } else if (kind == XCB_CONFIGURE_NOTIFY) {
            auto* cn = reinterpret_cast<xcb_configure_notify_event_t*>(ev);
            const QByteArray n = name(cn->window);
            if (!n.isEmpty())
                std::fprintf(stderr, "[xconf] %lld %s %ux%u\n", now(), n.constData(), cn->width, cn->height);
        }
        return false;
    }
private:
    static long long now() { return QDateTime::currentMSecsSinceEpoch(); }
    static QByteArray name(xcb_window_t id) {
        for (QWindow* w : QGuiApplication::topLevelWindows())
            if (w->handle() && xcb_window_t(w->winId()) == id) return w->title().toUtf8();
        return QByteArray();
    }
    xcb_atom_t protocols_, sync_;
};
}  // namespace

void x11InstallSyncTrace() {
    static SyncTrace* trace = nullptr;
    xcb_connection_t* c = connection();
    if (trace || !c) return;
    trace = new SyncTrace(c);
    QCoreApplication::instance()->installNativeEventFilter(trace);
}

namespace {
// Answers the window manager's _NET_WM_SYNC_REQUEST only once Present CompleteNotify
// says the first frame swapped after the configure has reached the window; Qt answers
// when glXSwapBuffers returns, before the copy lands (24-38% of resize frames stale -> 0%).
// MELO_X11_PRESENT_SYNC=0 turns it off, MELO_X11_PRESENT_LOG=1 logs each answer.
class PresentSync : public QObject, public QAbstractNativeEventFilter {
public:
    PresentSync(QQuickWindow* w, xcb_connection_t* c) : QObject(w), m_c(c), m_xid(xcb_window_t(w->winId())) {
        m_log = qEnvironmentVariableIsSet("MELO_X11_PRESENT_LOG");
        const auto* pq = xcb_get_extension_data(m_c, &xcb_present_id);
        if (!pq || !pq->present) return;
        m_presentOp = pq->major_opcode;
        std::free(xcb_present_query_version_reply(m_c, xcb_present_query_version(m_c, 1, 2), nullptr));
        m_protocols = internAtom(m_c, "WM_PROTOCOLS");
        m_syncRequest = internAtom(m_c, "_NET_WM_SYNC_REQUEST");
        const xcb_atom_t aCounter = internAtom(m_c, "_NET_WM_SYNC_REQUEST_COUNTER");
        auto* r = xcb_get_property_reply(m_c, xcb_get_property(m_c, 0, m_xid, aCounter, XCB_ATOM_ANY, 0, 1), nullptr);
        if (r && xcb_get_property_value_length(r) >= 4) m_counter = *static_cast<uint32_t*>(xcb_get_property_value(r));
        std::free(r);
        if (!m_counter) return;
        xcb_present_select_input(m_c, xcb_generate_id(m_c), m_xid, XCB_PRESENT_EVENT_MASK_COMPLETE_NOTIFY);
        xcb_flush(m_c);
        connect(w, &QQuickWindow::frameSwapped, this, [this] { onSwapped(); }, Qt::DirectConnection);
        m_timeout.setSingleShot(true);
        m_timeout.setInterval(100);   // never hold the window manager longer than this
        connect(&m_timeout, &QTimer::timeout, this, [this] { answer("timeout"); });
        QCoreApplication::instance()->installNativeEventFilter(this);
        m_clock.start();
        m_on = true;
        m_name = w->title();
        if (m_log) std::fprintf(stderr, "[presentsync] %s on\n", qPrintable(w->title()));
    }
    ~PresentSync() override { if (m_on) QCoreApplication::instance()->removeNativeEventFilter(this); }

    bool nativeEventFilter(const QByteArray& type, void* message, qintptr*) override {
        if (type != "xcb_generic_event_t") return false;
        auto* e = static_cast<xcb_generic_event_t*>(message);
        const uint8_t t = e->response_type & 0x7f;
        if (t == XCB_CLIENT_MESSAGE) {
            auto* cm = reinterpret_cast<xcb_client_message_event_t*>(e);
            if (cm->window == m_xid && cm->type == m_protocols && cm->data.data32[0] == m_syncRequest) {
                m_serial.lo = cm->data.data32[2];
                m_serial.hi = int32_t(cm->data.data32[3]);
                m_pending = true;
                m_configured = false;
                m_target = -1;
                m_timeout.start();   // a request no configure follows is answered by this
                if (m_log) std::fprintf(stderr, "[presentsync] %s request %u at %lld ms\n", qPrintable(m_name), m_serial.lo,
                                        static_cast<long long>(m_clock.elapsed()));
                return true;   // Qt never sees it, so it never sets the counter itself
            }
        } else if (t == XCB_CONFIGURE_NOTIFY) {
            auto* ce = reinterpret_cast<xcb_configure_notify_event_t*>(e);
            if (ce->window == m_xid && m_pending && !m_configured) {
                m_configured = true;
                m_timeout.start();
            }
        } else if (t == XCB_GE_GENERIC) {
            auto* ge = reinterpret_cast<xcb_ge_generic_event_t*>(e);
            if (ge->extension == m_presentOp && ge->event_type == XCB_PRESENT_EVENT_COMPLETE_NOTIFY) {
                auto* pe = reinterpret_cast<xcb_present_complete_notify_event_t*>(e);
                if (pe->window == m_xid && pe->kind == XCB_PRESENT_COMPLETE_KIND_PIXMAP) {
                    ++m_completes;
                    if (m_target >= 0 && m_completes >= m_target) answer("present");
                    return true;
                }
            }
        }
        return false;
    }

private:
    void onSwapped() {
        ++m_swaps;
        // the first frame swapped after the configure is the one the window manager waits for
        if (m_pending && m_configured && m_target < 0) {
            m_target = m_swaps;
            if (m_completes >= m_target) answer("present");
        }
    }
    void answer(const char* why) {
        if (!m_pending) return;
        xcb_sync_set_counter(m_c, m_counter, m_serial);
        xcb_flush(m_c);
        if (m_log) std::fprintf(stderr, "[presentsync] %s answer %u via %s at %lld ms\n", qPrintable(m_name), m_serial.lo, why,
                                static_cast<long long>(m_clock.elapsed()));
        m_pending = false; m_configured = false; m_target = -1;
        m_timeout.stop();
    }

    xcb_connection_t* m_c;
    xcb_window_t m_xid;
    QString m_name;
    xcb_sync_counter_t m_counter = 0;
    xcb_atom_t m_protocols = 0, m_syncRequest = 0;
    uint8_t m_presentOp = 0;
    xcb_sync_int64_t m_serial {0, 0};
    bool m_pending = false, m_configured = false, m_log = false, m_on = false;
    qint64 m_swaps = 0, m_completes = 0, m_target = -1;
    QTimer m_timeout;
    QElapsedTimer m_clock;
};
}  // namespace

void x11PresentSync(QQuickWindow* w) {
    xcb_connection_t* c = connection();
    if (!w || !c || qEnvironmentVariable("MELO_X11_PRESENT_SYNC") == QLatin1String("0")) return;
    if (w->property("meloPresentSync").toBool()) return;
    w->setProperty("meloPresentSync", true);
    new PresentSync(w, c);
}

namespace {
// A window starts at _NET_WM_WINDOW_OPACITY 0 and loses it with its first frame:
// an X window shows from its map, before anything is drawn in it, black.
class FirstFrameGate : public QObject {
public:
    FirstFrameGate(xcb_connection_t* c, QStringList skip) : m_c(c), m_skip(std::move(skip)) {
        m_opacity = internAtom(c, "_NET_WM_WINDOW_OPACITY");
    }
    bool eventFilter(QObject* o, QEvent* e) override {
        if (e->type() != QEvent::PlatformSurface
            || static_cast<QPlatformSurfaceEvent*>(e)->surfaceEventType() != QPlatformSurfaceEvent::SurfaceCreated)
            return false;
        auto* w = qobject_cast<QQuickWindow*>(o);
        if (!w || m_skip.contains(w->title())) return false;
        const xcb_window_t xid = xcb_window_t(w->winId());
        const uint32_t zero = 0;
        xcb_change_property(m_c, XCB_PROP_MODE_REPLACE, xid, m_opacity, XCB_ATOM_CARDINAL, 32, 1, &zero);
        xcb_flush(m_c);
        auto* once = new QObject(w);
        auto reveal = [c = m_c, a = m_opacity, xid, once] {
            xcb_delete_property(c, xid, a);
            xcb_flush(c);
            once->deleteLater();
        };
        connect(w, &QQuickWindow::frameSwapped, once, reveal, Qt::QueuedConnection);
        QTimer::singleShot(1000, once, reveal);   // never left hidden
        return false;
    }

private:
    xcb_connection_t* m_c;
    QStringList m_skip;
    xcb_atom_t m_opacity = 0;
};
}  // namespace

namespace {
// Adds SKIP_TASKBAR and SKIP_PAGER to _NET_WM_STATE between QShowEvent and the map:
// Qt merges what is there when it writes its own states, and the window manager
// clears the property on every unmap.
class TaskbarSkip : public QObject {
public:
    TaskbarSkip(xcb_connection_t* c, QStringList titles) : m_c(c), m_titles(std::move(titles)) {
        m_state = internAtom(c, "_NET_WM_STATE");
        m_add[0] = internAtom(c, "_NET_WM_STATE_SKIP_TASKBAR");
        m_add[1] = internAtom(c, "_NET_WM_STATE_SKIP_PAGER");
    }
    bool eventFilter(QObject* o, QEvent* e) override {
        if (e->type() != QEvent::Show) return false;
        auto* w = qobject_cast<QWindow*>(o);
        if (!w || !w->handle() || !(m_titles.contains(w->title()) || w->title().startsWith(QLatin1String("melo-plugin-"))))
            return false;
        const xcb_window_t xid = xcb_window_t(w->winId());
        std::vector<xcb_atom_t> atoms;
        if (auto* r = xcb_get_property_reply(m_c, xcb_get_property(m_c, false, xid, m_state, XCB_ATOM_ATOM, 0, 1024), nullptr)) {
            const auto* a = static_cast<const xcb_atom_t*>(xcb_get_property_value(r));
            atoms.assign(a, a + xcb_get_property_value_length(r) / int(sizeof(xcb_atom_t)));
            std::free(r);
        }
        for (xcb_atom_t a : m_add)
            if (std::find(atoms.begin(), atoms.end(), a) == atoms.end()) atoms.push_back(a);
        xcb_change_property(m_c, XCB_PROP_MODE_REPLACE, xid, m_state, XCB_ATOM_ATOM, 32,
                            quint32(atoms.size()), atoms.data());
        xcb_flush(m_c);
        return false;
    }

private:
    xcb_connection_t* m_c;
    QStringList m_titles;
    xcb_atom_t m_state = 0;
    xcb_atom_t m_add[2] = {};
};
}  // namespace

void x11SkipTaskbar(const QStringList& titles) {
    static TaskbarSkip* skip = nullptr;
    xcb_connection_t* c = connection();
    if (skip || !c) return;
    skip = new TaskbarSkip(c, titles);
    QCoreApplication::instance()->installEventFilter(skip);
}

void x11HideUntilDrawn(const QStringList& skip) {
    static FirstFrameGate* gate = nullptr;
    xcb_connection_t* c = connection();
    if (gate || !c || qEnvironmentVariable("MELO_X11_DRAW_GATE") == QLatin1String("0")) return;
    gate = new FirstFrameGate(c, skip);
    QCoreApplication::instance()->installEventFilter(gate);
}
