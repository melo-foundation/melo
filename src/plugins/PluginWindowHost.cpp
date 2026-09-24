#include "PluginWindowHost.h"
#include "PluginUiHost.h"
#include "SpectrumSource.h"
#include "WindowController.h"

#include <QJsonArray>
#include <QLoggingCategory>
#include <QJsonObject>
#include <QPolygon>
#include <QQuickItem>
#include <QQuickWindow>
#include <QGuiApplication>
#include <QScopedValueRollback>
#include <QSet>
#include <QTimer>
#include <QtMath>
#include <QtNumeric>
#include <cstdio>
#include <atomic>

// Opt-in trace for the one thing that cannot be seen from a unit test: what a
// LIVE compositor actually reports while a window is dragged, and what this
// host does with each report. Off by default; turn it on with
//   QT_LOGGING_RULES="melo.plugin.windows.debug=true"
Q_LOGGING_CATEGORY(loggerWindows, "melo.plugin.windows", QtWarningMsg)

// Captions are interpolated into KWin scripts and matched back by string, so
// only an ASCII slug is accepted: KWin returns U+2028/U+2029 as spaces (the
// caption never matches), and '%' is a QString::arg marker. Rejected rather
// than folded so the author gets a named error at load. A second gate behind
// manifest validation.
static bool captionSafe(const QString& s) {
    if (s.isEmpty() || s.size() > 64) return false;
    for (const QChar c : s) {
        const ushort u = c.unicode();
        const bool ok = (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z')
                     || (u >= '0' && u <= '9') || u == '-' || u == '_';
        if (!ok) return false;
    }
    return true;
}

// A spectrum key no other live host holds; a shared key would let one host
// release another's FFT (see the header). Monotonic, never reused, so no
// liveness check is needed; the first host gets the bare name.
static QString nextSpectrumOwner() {
    static std::atomic<int> n{0};
    const int i = n.fetch_add(1);
    return i == 0 ? QStringLiteral("plugin-windows")
                  : QStringLiteral("plugin-windows#%1").arg(i);
}

PluginWindowHost::PluginWindowHost(PluginUiHost* ui, MeloUi* bridge, QWindow* transientParent,
                                   WindowController* wc, SpectrumSource* spectrum,
                                   QObject* parent)
    : QObject(parent), ui_(ui), bridge_(bridge), transientParent_(transientParent), wc_(wc),
      spectrum_(spectrum), spectrumOwner_(nextSpectrumOwner()) {

    // Never run plugin code from inside the shell's bookkeeping. A facade's
    // changed() runs plugin bindings, which can trigger a rebuild that destroys
    // this host, mid-walk over `wins_` if emitted from moveWindow. So only the
    // signal is queued to the event loop; property values are already current.
    notify_ = new QTimer(this);
    notify_->setSingleShot(true);
    notify_->setInterval(0);
    connect(notify_, &QTimer::timeout, this, [this] {
        const QStringList ids = pendingNotify_;
        pendingNotify_.clear();
        // ...and even here one notification can destroy this host before the
        // next. `ids` is a local copy so the loop itself survives; the guard is
        // what stops it reaching into a freed `wins_`.
        QPointer<PluginWindowHost> alive(this);
        for (const QString& id : ids) {
            if (!alive) return;
            const auto it = wins_.constFind(id);
            if (it != wins_.cend() && it->facade) it->facade->notifyChanged();
        }
    });

    // The resize counterpart of settle_: re-seating the docked group costs a
    // blocking KWin DBus round trip, so it waits out a grip drag's per-frame
    // configures. Quantisation is local and is not deferred. Started only when
    // idle; KWin's move glue handles live translation, this handles reflow.
    resettle_ = new QTimer(this);
    resettle_->setSingleShot(true);
    resettle_->setInterval(120);
    connect(resettle_, &QTimer::timeout, this, [this] {
        // A pending drag settle owns `lastPos`; reflowing first would rewrite
        // it, giving applySnap a null delta and stranding the docked group.
        if (settle_ && settle_->isActive()) { resettle_->start(); return; }
        const QStringList ids = pendingReflow_;
        pendingReflow_.clear();
        for (const QString& id : ids) reflowDocked(id);
    });

    // The main window's REAL position, from the same KWin watcher melo's saved
    // window position already trusts. transientParent_->position() is the
    // client's own guess, and on Wayland that is fiction — using it would place
    // the primary plugin window at the origin instead of over melo.
    if (wc_) {
        connect(wc_, &WindowController::mainGeometry, this,
                [this](int x, int y, int, int, bool) {
            mainPos_ = QPoint(x, y);
            haveMainPos_ = true;
            if (placeWanted_) { placeWanted_ = false; placeInitial(); }
        });
        // Wayland has no position event, so KWin's report after a user move is
        // the only way melo learns where a window went. Size is client-owned
        // and ignored.
        connect(wc_, &WindowController::windowGeometry, this,
                [this](const QString& caption, int x, int y, int, int) {
            onWindowGeometry(caption, x, y);
        });
    }
}

// Every position read in this file goes through here, never QWindow::position(),
// which a Wayland client is never told. `pos` comes from moveWindow, KWin's
// reports (onWindowGeometry) and xChanged/yChanged on X11/Windows.
QPoint PluginWindowHost::posOf(const Win& w) { return w.pos; }

void PluginWindowHost::notifyLater(const QString& id) {
    if (!pendingNotify_.contains(id)) pendingNotify_ << id;
    if (notify_ && !notify_->isActive()) notify_->start();
}

// The four flush positions, in one place. snapTarget's magnetism candidates and
// reflowDocked's re-seating both come from here, so a window can never be
// re-seated somewhere magnetism would not have snapped it.
QPoint PluginWindowHost::dockPoint(const QRect& t, Dock edge, const QSize& size) {
    switch (edge) {
    case Dock::Below: return QPoint(t.x(), t.y() + t.height());   // the Winamp dock
    case Dock::Above: return QPoint(t.x(), t.y() - size.height());
    case Dock::Right: return QPoint(t.x() + t.width(), t.y());
    case Dock::Left:  return QPoint(t.x() - size.width(), t.y());
    case Dock::None:  break;
    }
    return QPoint();
}

// A window's size in the docking chain: its own while shown, zero while hidden,
// so a hidden window leaves no gap (magnetism could not close one later). Every
// dockPoint() argument comes from here. Uses `wanted`, not `active_ && wanted`,
// so silencing the host does not collapse the chain.
QSize PluginWindowHost::dockSize(const Win& w) {
    if (!w.win) return QSize();
    return w.wanted ? w.size : QSize(0, 0);
}

// The largest edge the quantiser computes (and setScale's temporary maximum),
// keeping `req - base + step/2` inside an int. Not a size policy.
static constexpr int kMaxWindowEdge = 16384;

// An axis's grid anchor and floor: the declared minimum if positive, else the
// declared size. Shared so quantiseAxis and applySizeLimits agree on the minimum.
static int axisBase(int minimum, int declared) { return minimum > 0 ? minimum : declared; }

// No limit: Qt's private QWINDOWSIZE_MAX, the only maximum QtWayland does not
// send to the compositor. Never advertise a real maximum: xdg_toplevel.set_max_size
// sends KWin's interactive resize down a path that deforms the window mid-drag.
static constexpr int kNoSizeLimit = (1 << 24) - 1;

// One axis of the quantiser. `free` is whether the manifest listed this axis in
// `axes`; everything else is that axis's own numbers.
static int quantiseAxis(int req, int declared, bool free, int minimum, int step) {
    if (!free) return declared;                      // the manifest pinned it
    const int base = axisBase(minimum, declared);
    const int want = qBound(1, req, kMaxWindowEdge);
    if (want <= base || step <= 0) return qMax(base, want);
    // Nearest permitted, which is what a drag wants: the edge follows the
    // pointer to the closer step rather than always the one behind it.
    const int k = (want - base + step / 2) / step;
    return base + k * step;
}

QSize PluginWindowHost::quantiseSize(const QJsonObject& decl, const QSize& req) {
    const int declW = decl.value(QStringLiteral("width")).toInt();
    const int declH = decl.value(QStringLiteral("height")).toInt();
    const QJsonObject r = decl.value(QStringLiteral("resize")).toObject();
    const QString axes = r.value(QStringLiteral("axes")).toString();
    // An axes value this shell does not know is NOT a free axis. The manifest
    // validator admits only v/h/vh, and anything that reaches here past it is
    // a window melo cannot honour — fixed size is the safe reading of it.
    const bool horz = axes == QLatin1String("h") || axes == QLatin1String("vh");
    const bool vert = axes == QLatin1String("v") || axes == QLatin1String("vh");
    return QSize(quantiseAxis(req.width(), declW, horz,
                              r.value(QStringLiteral("minWidth")).toInt(),
                              r.value(QStringLiteral("stepW")).toInt()),
                 quantiseAxis(req.height(), declH, vert,
                              r.value(QStringLiteral("minHeight")).toInt(),
                              r.value(QStringLiteral("stepH")).toInt()));
}

// See the header for why bottom and right only. The refusal is the point: a
// `v`-only window handed Qt::RightEdge is DRAGGABLE SIDEWAYS, and the quantiser
// then snaps the width back on every configure — a rubber-banding edge rather
// than one the compositor never offers.
Qt::Edges PluginWindowHost::resizeEdges(const QJsonObject& decl) {
    const QString axes = decl.value(QStringLiteral("resize")).toObject()
                             .value(QStringLiteral("axes")).toString();
    Qt::Edges e;
    if (axes == QLatin1String("v") || axes == QLatin1String("vh")) e |= Qt::BottomEdge;
    if (axes == QLatin1String("h") || axes == QLatin1String("vh")) e |= Qt::RightEdge;
    return e;
}

// The three gates, where a test can see them. See the header.
Qt::Edges PluginWindowHost::resizeGrabEdges(const QString& id) const {
    const auto it = wins_.constFind(id);
    if (it == wins_.cend() || !it->win) return {};
    // Same gate as the drag: a window nobody can see must not be resizable
    // either, or a grip under the pointer moves something invisible.
    if (!active_ || !it->wanted) return {};
    // A shaded window is at its shade height, which is not a size the resize
    // block permits — dropping the grab is the honest answer, because the
    // alternative is a resize the next quantise pass throws away.
    if (it->shaded) return {};
    return resizeEdges(it->decl);   // ...and {} again for a window that declared none
}

void PluginWindowHost::applySizeLimits(Win& w) {
    if (!w.win) return;
    const int declW = w.decl.value(QStringLiteral("width")).toInt();
    const int declH = w.decl.value(QStringLiteral("height")).toInt();
    // Shaded is its own fixed size, outside the resize range; resize limits
    // left in place would pull the window back up to the minimum.
    if (w.shaded) {
        const int shadeH = w.decl.value(QStringLiteral("shade")).toObject()
                                 .value(QStringLiteral("height")).toInt();
        if (shadeH > 0) {
            w.win->setMinimumSize(QSize(declW, shadeH));
            w.win->setMaximumSize(QSize(declW, shadeH));
            return;
        }
    }
    const QJsonObject r = w.decl.value(QStringLiteral("resize")).toObject();
    const QString axes = r.value(QStringLiteral("axes")).toString();
    const bool horz = axes == QLatin1String("h") || axes == QLatin1String("vh");
    const bool vert = axes == QLatin1String("v") || axes == QLatin1String("vh");
    // axisBase, not a second reading of the same field: what the compositor is
    // told the floor is has to be the floor the quantiser rounds to.
    const int minW = horz ? axisBase(r.value(QStringLiteral("minWidth")).toInt(), declW) : declW;
    const int minH = vert ? axisBase(r.value(QStringLiteral("minHeight")).toInt(), declH) : declH;
    // A window that declared no `resize` is min == max == what it declared,
    // and that is the whole of "a plain plugin window is a fixed-size window":
    // without it the compositor's own resize gestures (KWin's Meta+RMB drag is
    // one) stretch a skin whose artwork cannot tile.
    w.win->setMinimumSize(QSize(minW, minH));
    // A PINNED axis still advertises its one legal size — that is what stops a
    // compositor gesture (KWin's Meta+RMB drag) stretching artwork that cannot
    // tile. A FREE axis advertises nothing at all.
    w.win->setMaximumSize(QSize(horz ? kNoSizeLimit : declW,
                                vert ? kNoSizeLimit : declH));
}

static int scaledPixel(int value, double scale, bool zeroMeansAbsent = false) {
    if (zeroMeansAbsent && value <= 0) return 0;
    return qMax(1, qRound(value * scale));
}

static QJsonObject scaledWindowDecl(const QJsonObject& logical, double scale) {
    QJsonObject d = logical;
    for (const QString& key : {QStringLiteral("width"), QStringLiteral("height")})
        d.insert(key, scaledPixel(logical.value(key).toInt(), scale));
    QJsonObject shade = logical.value(QStringLiteral("shade")).toObject();
    if (!shade.isEmpty()) {
        shade.insert(QStringLiteral("height"),
                     scaledPixel(shade.value(QStringLiteral("height")).toInt(), scale));
        d.insert(QStringLiteral("shade"), shade);
    }
    QJsonObject resize = logical.value(QStringLiteral("resize")).toObject();
    if (!resize.isEmpty()) {
        for (const QString& key : {QStringLiteral("stepH"), QStringLiteral("stepW"),
                                   QStringLiteral("minHeight"), QStringLiteral("minWidth")})
            if (resize.contains(key))
                resize.insert(key, scaledPixel(resize.value(key).toInt(), scale, true));
        d.insert(QStringLiteral("resize"), resize);
    }
    return d;
}

static QSize quantiseAtScale(const QJsonObject& logicalDecl, const QSize& physical,
                             double scale) {
    const QSize logical(qRound(physical.width() / scale),
                        qRound(physical.height() / scale));
    const QSize permitted = PluginWindowHost::quantiseSize(logicalDecl, logical);
    return QSize(qMax(1, qRound(permitted.width() * scale)),
                 qMax(1, qRound(permitted.height() * scale)));
}

static QRegion scaledRegion(const QRegion& source, double scale) {
    if (qFuzzyCompare(scale, 1.0) || source.isEmpty()) return source;
    QRegion out;
    for (const QRect& r : source) {
        const int left = qRound(r.left() * scale);
        const int top = qRound(r.top() * scale);
        const int right = qRound((r.right() + 1) * scale);
        const int bottom = qRound((r.bottom() + 1) * scale);
        if (right > left && bottom > top)
            out += QRegion(left, top, right - left, bottom - top);
    }
    return out;
}

PluginWindowHost::~PluginWindowHost() { teardown(); }

bool PluginWindowHost::build(const QJsonObject& uiBlock, double scale) {
    error_.clear();
    scale_ = qBound(0.5, qIsFinite(scale) ? scale : 1.0, 4.0);
    if (!ui_ || !bridge_) { error_ = QStringLiteral("no plugin ui host"); return false; }
    if (!wins_.isEmpty()) { error_ = QStringLiteral("already built"); return false; }

    const QString pluginId = bridge_->pluginId();
    if (!captionSafe(pluginId)) {
        error_ = QStringLiteral("plugin id is not usable as a window caption: %1").arg(pluginId);
        return false;
    }
    const QJsonArray decls = uiBlock.value(QStringLiteral("windows")).toArray();
    if (decls.isEmpty()) { error_ = QStringLiteral("ui.windows is empty"); return false; }
    // Clamped, not trusted: the manifest validator rejects a negative distance,
    // but this value drives an every-move comparison and must be sane whatever
    // reaches it.
    baseSnapDistance_ = qBound(0, uiBlock.value(QStringLiteral("snap")).toObject()
                                      .value(QStringLiteral("distance")).toInt(10), 200);
    snapDistance_ = qRound(baseSnapDistance_ * scale_);

    // PASS 1 — every window and facade exists before ANY plugin QML runs, so a
    // window's Component.onCompleted can already read MeloUi.window.
    for (const QJsonValue& v : decls) {
        const QJsonObject logicalDecl = v.toObject();
        QJsonObject d = scaledWindowDecl(logicalDecl, scale_);
        const QString id = d.value(QStringLiteral("id")).toString();
        if (!captionSafe(id)) {
            error_ = QStringLiteral("window id is not usable as a window caption: %1").arg(id);
            teardown();
            return false;
        }
        if (wins_.contains(id)) {
            error_ = QStringLiteral("duplicate window id: %1").arg(id);
            teardown();
            return false;
        }
        const int w = d.value(QStringLiteral("width")).toInt();
        const int h = d.value(QStringLiteral("height")).toInt();
        if (w <= 0 || h <= 0) {
            error_ = QStringLiteral("window %1: width and height must be positive").arg(id);
            teardown();
            return false;
        }

        Win rec;
        rec.logicalDecl = logicalDecl;
        rec.decl = d;
        rec.id = id;
        rec.title = QStringLiteral("melo-plugin-%1-%2").arg(pluginId, id);
        rec.wanted = d.value(QStringLiteral("initial")).toString() != QStringLiteral("hidden");
        rec.fullHeight = h;
        // EXACTLY miniWin's configuration (Main.qml). Transiency is what
        // keeps the taskbar at one entry; do not drop it. Frameless + transparent
        // because the plugin paints everything, chrome included.
        rec.win = new QQuickWindow();
        rec.win->setTransientParent(transientParent_.data());
        rec.win->setFlags(Qt::Window | Qt::FramelessWindowHint);
        rec.win->setColor(Qt::transparent);
        rec.win->setTitle(rec.title);
        rec.win->resize(w, h);
        // The shell-owned gate the plugin's root hangs off (see Win::gate).
        rec.size = QSize(w, h);
        rec.gate = new QQuickItem(rec.win->contentItem());
        rec.gate->setSize(QSizeF(w, h));
        rec.facade = new MeloUiWindow(id, this, this);
        rec.lastPos = rec.pos = rec.win->position();

        wins_.insert(id, rec);
        order_ << id;
        if (d.value(QStringLiteral("primary")).toBool()) primaryId_ = id;

        QQuickWindow* win = rec.win;
        // THE X11/WINDOWS DOOR for a user drag. On Wayland this never fires for
        // one — no position event reaches the client — which is why the
        // compositor-side watcher (onWindowGeometry) exists.
        auto moved = [this, id] {
            auto it = wins_.find(id);
            if (it == wins_.end() || !it->win) return;
            notifyLater(id);
            if (moving_) { it->lastPos = it->win->position(); return; }   // our own move
            // Once KWin has reported this window, position() is fiction and
            // KWin is the only writer of `pos` — a stray notification must not
            // overwrite a real report with the client's stale guess.
            if (it->kwinOwnsPos) return;
            // An unchanged position is not a move. `moving_` cannot tell: the
            // platform delivers melo's own setPosition after it unwinds, and
            // treating that as a drag would overwrite the single `movedId_` slot
            // a real pending drag is waiting in.
            if (it->pos == it->win->position()) return;
            it->pos = it->win->position();
            movedId_ = id;
            settle_->start();
        };
        connect(win, &QWindow::xChanged, this, [moved](int) { moved(); });
        connect(win, &QWindow::yChanged, this, [moved](int) { moved(); });
        // The gate carries the authoritative size (`anchors.fill: parent`). The
        // plugin root is also resized, best effort, so a root that neither
        // anchors nor binds a size still follows shade; a bound size wins.
        auto resized = [this, id] {
            auto it = wins_.find(id);
            if (it == wins_.end() || !it->win) return;
            // Win::size is written before the guards below, because every size
            // a panel takes passes through here. A group host's window is the
            // whole stack, sized by applyGroups, so it is skipped.
            if (it->hostsPanels > 1) return;
            it->size = QSize(it->win->width(), it->win->height());
            // Where the manifest's `resize` is enforced. xdg_toplevel carries no
            // size increment, so the client accepts each configure, quantises,
            // and resizes back; quantiseSize is idempotent, so it converges.
            // Runs during a grip drag so growth lands on the steps. Skipped
            // while shaded (the shade height is off the grid, and `shaded` is
            // set before the shade resize for this) and during a user move (a
            // move configure would jump on the grid). Re-seating neighbours goes
            // through KWin and stays deferred.
            const bool resizingNow = id == holdId_;
            if (!it->shaded && !it->userMoving) {
                const QSize cur(it->win->width(), it->win->height());
                const QSize want = quantiseAtScale(it->logicalDecl, cur, scale_);
                if (want != cur) {
                    qCDebug(loggerWindows) << "QUANTISE" << id << cur << "->" << want;
                    it->win->resize(want);
                }
            }
            const QSizeF sz(it->win->width(), it->win->height());
            if (it->gate) {
                it->gate->setSize(sz);
                const QSizeF logical(sz.width() / scale_, sz.height() / scale_);
                for (QQuickItem* child : it->gate->childItems()) {
                    child->setScale(scale_);
                    child->setTransformOrigin(QQuickItem::TopLeft);
                    child->setSize(logical);
                }
            }
            notifyLater(id);
            // Docked neighbours were flush against an edge that just moved. A
            // resize changes no position, so applySnap cannot re-seat them and
            // they end up outside the snap distance; the shade toggle does the same.
            if (!it->userMoving && !resizingNow) reflowLater(id);
        };
        connect(win, &QWindow::widthChanged, this, [resized](int) { resized(); });
        connect(win, &QWindow::heightChanged, this, [resized](int) { resized(); });

        // AFTER the connections, so a size these two lines change still syncs
        // the gate and the plugin's root through the one path that does it.
        Win& made = wins_[id];
        applySizeLimits(made);
        // The declared size is quantised too, or an off-grid window jumps on
        // its first grip drag. Warned, not refused: the corrected size works.
        const QSize declared(w, h);
        const QSize want = quantiseAtScale(made.logicalDecl, declared, scale_);
        if (want != declared) {
            std::fprintf(stderr, "[melo] plugin %s: window %s declares %dx%d, which its own "
                                 "resize block does not permit — opening at %dx%d\n",
                         pluginId.toUtf8().constData(), id.toUtf8().constData(),
                         declared.width(), declared.height(), want.width(), want.height());
            made.win->resize(want);
            made.size = want;
            made.fullHeight = want.height();
        }
    }
    if (primaryId_.isEmpty()) primaryId_ = order_.first();

    QVariantMap facades;
    for (const QString& id : order_)
        facades.insert(id, QVariant::fromValue(static_cast<QObject*>(wins_[id].facade)));
    bridge_->setWindows(facades);

    // PASS 2 — content. The window is passed as the parent; PluginUiHost
    // resolves contentItem() itself and OWNS what it returns (setParent), so
    // nothing here deletes it.
    for (const QString& id : order_) {
        Win& rec = wins_[id];
        QObject* content = ui_->createWindowContent(
            rec.decl.value(QStringLiteral("qml")).toString(), rec.gate);
        if (!content) {
            error_ = ui_->errorString();
            teardown();
            return false;
        }
        // A one-time default so a root that neither anchors nor declares a size
        // is not 0x0. From here on the gate carries the window's size, and a
        // plugin that binds its own width/height owns the consequences.
        if (auto* item = qobject_cast<QQuickItem*>(content)) {
            const QSizeF logical(rec.win->width() / scale_, rec.win->height() / scale_);
            item->setScale(scale_);
            item->setTransformOrigin(QQuickItem::TopLeft);
            item->setSize(logical);
        }
        // Mapped for life. "Hidden" is never unmapped —
        // mapping/unmapping fires WM open/close animations and loses position.
        rec.win->setVisible(true);
        rec.win->installEventFilter(this);   // the resize freeze; see setFrozen
    }

    placeInitial();
    // After placeInitial, so the arm-time report usually describes placed
    // windows. Not guaranteed (placeInitial may defer on Wayland), which is why
    // onWindowGeometry adopts a window's first report rather than treating it
    // as a drag.
    watchWindows();
    // Live after build. Compact is first-party chrome and must not be the
    // thing that turns plugin windows on. wanted / initial decide which of
    // these paint; active_ is the host-level switch and starts true.
    setActive(true);
    return true;
}

// Watches every window this host owns: a hidden window stays mapped with its
// caption, so show/hide would only add a KWin round trip per toggle.
void PluginWindowHost::watchWindows() {
    // The always-up script names the same captions, so it goes stale in exactly
    // the same places the watcher does.
    if (alwaysUp_ && wc_) wc_->setPluginWindowsAlwaysUp(windowTitles(), true);
    if (wc_) wc_->watchWindowGeometry(windowTitles());
}

void PluginWindowHost::syncWindowGlue() {
    if (!wc_) return;
    QVariantList links;
    QHash<QString, QHash<QString, QPoint>> installedLinks;
    // One direct leader -> EVERY descendant link, rather than relying on a
    // chain of frameGeometryChanged callbacks to settle over several frames.
    // KWin therefore moves a three-panel Winamp stack in one compositor pass.
    for (const QString& leaderId : order_) {
        const Win& leader = wins_[leaderId];
        if (!leader.win || !leader.wanted) continue;
        for (const QString& followerId : order_) {
            if (followerId == leaderId) continue;
            const Win& follower = wins_[followerId];
            if (!follower.win || !follower.wanted) continue;

            QString cur = followerId;
            QSet<QString> seen;
            bool descendant = false;
            int budget = order_.size() + 1;
            while (budget-- > 0 && wins_.contains(cur) && !seen.contains(cur)) {
                seen.insert(cur);
                const Win& child = wins_[cur];
                if (!child.docked) break;
                const QString parent = child.decl.value(QStringLiteral("snapTo")).toString();
                if (parent == leaderId) { descendant = true; break; }
                if (parent.isEmpty() || parent == cur) break;
                cur = parent;
            }
            if (!descendant) continue;
            const QPoint d = posOf(follower) - posOf(leader);
            installedLinks[leaderId][followerId] = d;
            links << QVariantMap{{QStringLiteral("leader"), leader.title},
                                 {QStringLiteral("follower"), follower.title},
                                 {QStringLiteral("dx"), d.x()},
                                 {QStringLiteral("dy"), d.y()}};
        }
    }
    // Only what KWin actually took. setPluginWindowGlue returns false where
    // there is no KWin to run it (X11, Windows, offscreen tests) — and there
    // the client's own setPosition IS the move, so nothing is carried for us
    // and suppressing the move would leave the window where it was.
    const bool installed = wc_->setPluginWindowGlue(links);
    glueLinks_ = installed ? installedLinks : QHash<QString, QHash<QString, QPoint>>{};
    qCDebug(loggerWindows) << "GLUE" << links.size() << "links, installed" << installed
                           << links;
}

void PluginWindowHost::teardown() {
    // Release the FFT first and unconditionally, not via syncSpectrum() over
    // records being destroyed: a host that dies holding the key pins the FFT on
    // for the life of the process.
    if (spectrum_) spectrum_->request(spectrumOwner_, false);
    // Before the windows go: the compositor-side watcher outlives this host
    // (WindowController belongs to main()), and a watcher left armed on dead
    // captions would report about whatever window claimed them next.
    if (wc_) {
        wc_->setPluginWindowGlue({});
        wc_->watchWindowGeometry(QStringList());
    }
    if (bridge_) bridge_->setWindows({});   // never leave plugin QML a freed facade
    for (const QString& id : order_) {
        Win& w = wins_[id];
        delete w.win;      // plugin content stays owned by PluginUiHost (~QQuickItem
        delete w.facade;   // clears its parentItem), which destroys it with its engine
    }
    wins_.clear();
    order_.clear();
    primaryId_.clear();
}

QVariantList PluginWindowHost::opacityEntries() const {
    QVariantList ops;
    for (const QString& id : order_) {
        const Win w = wins_.value(id);
        const bool eff = active_ && w.wanted;
        ops << QVariantMap{{QStringLiteral("title"), w.title},
                           {QStringLiteral("opacity"), eff ? 1.0 : 0.0}};
    }
    return ops;
}

void PluginWindowHost::setActive(bool on, bool applyOpacity) {
    active_ = on;
    applyState(applyOpacity);
    for (const QString& id : order_) notifyLater(id);
}

// Holding a frame: during a resize every other window swallows
// QEvent::UpdateRequest, so its surface does not commit and keeps its last
// buffer. Any window rendering on the shared GUI thread (basic render loop)
// delays the resized window's configure answer, which the compositor then
// stretches. Hiding would commit a blank frame. Animations keep advancing and
// the thaw renders once.
//
// beginHold is the user's own grip resize, which arrives through
// PluginWindowBackend rather than KWin. The quantiser and docked reflow stand
// down until endHold.
void PluginWindowHost::beginHold(const QString& id) {
    if (holdId_ == id) return;
    holdId_ = id;
    // Every window in the process holds, melo's own most of all: on the basic
    // render loop its frames land between the configure and the plugin's
    // answer, and the plugin window deforms. An application-wide filter also
    // catches the visualiser and compact windows; it is installed only while a
    // grip is held.
    qApp->installEventFilter(this);
    // Pointer events from the startSystemResize handover arrive after the grab
    // begins and would end the hold at once, so ignore the pointer for 250 ms.
    // This gates only the start; holding still cannot trigger it.
    holdArmed_ = false;
    QTimer::singleShot(250, this, [this] { holdArmed_ = true; });
}

void PluginWindowHost::endHold() {
    if (holdId_.isEmpty()) return;
    const QString id = holdId_;
    holdId_.clear();          // FIRST: the quantise below goes back through
                              // `resized`, which is the code being guarded
    holdArmed_ = false;
    qApp->removeEventFilter(this);
    // The frames that were refused, for everything that was holding one.
    for (QWindow* w : QGuiApplication::topLevelWindows())
        if (w->isVisible()) w->requestUpdate();
    auto it = wins_.find(id);
    if (it == wins_.end() || !it->win || it->shaded) return;
    const QSize cur(it->win->width(), it->win->height());
    const QSize want = quantiseAtScale(it->logicalDecl, cur, scale_);
    if (want != cur) it->win->resize(want);
    reflowLater(id);
}

void PluginWindowHost::setAlwaysUp(bool on) {
    if (alwaysUp_ == on) return;
    alwaysUp_ = on;
    if (wc_) wc_->setPluginWindowsAlwaysUp(windowTitles(), alwaysUp_);
}

void PluginWindowHost::setFrozen(bool on) {
    if (frozen_ == on) return;
    frozen_ = on;
    if (frozen_) return;
    // Without KWin nothing reports the grab ended, so the shell's own release
    // is the only notice a window left mid-hold ever gets.
    endHold();
    // Thawed: nothing dirtied the scene while the updates were being dropped,
    // so ask for the frame that was refused.
    for (const QString& id : order_)
        if (QQuickWindow* w = wins_.value(id).win) w->update();
}

// Every plugin window is filtered from build(); see setFrozen.
bool PluginWindowHost::eventFilter(QObject* obj, QEvent* ev) {
    // A grip is held: melo's window and every plugin window EXCEPT the one
    // being resized hold their last frame. See beginHold.
    if (!holdId_.isEmpty()) {
        // The compositor owns the pointer during an interactive resize, so the
        // first pointer event afterwards is the release (melo's own rule for its
        // window). Not a configure timer: holding the grip still stops configures.
        if (holdArmed_) {
            // A button release is the end wherever it lands. Hover coming back
            // is the end only on the window being dragged: the pointer is over
            // it for the whole resize, so the moment it is delivered there
            // again is the moment the compositor gave it back.
            const bool onHeld = obj == wins_.value(holdId_).win;
            switch (ev->type()) {
            case QEvent::MouseButtonRelease:
                // Queued: this is inside the filter, and endHold resizes.
                QTimer::singleShot(0, this, [this] { endHold(); });
                break;
            case QEvent::Enter: case QEvent::HoverEnter: case QEvent::HoverMove:
            case QEvent::MouseMove:
                if (onHeld) QTimer::singleShot(0, this, [this] { endHold(); });
                break;
            default: break;
            }
        }
        if (ev->type() == QEvent::UpdateRequest
            && obj != wins_.value(holdId_).win && qobject_cast<QWindow*>(obj))
            return true;              // hold that window's last frame
    }
    if (frozen_ && ev->type() == QEvent::UpdateRequest) {
        for (const QString& id : order_)
            if (wins_.value(id).win == obj) return true;   // refuse the render
    }
    return QObject::eventFilter(obj, ev);
}

void PluginWindowHost::applyState(bool applyOpacity) {
    for (const QString& id : order_) {
        Win& w = wins_[id];
        if (!w.win) continue;
        const bool eff = active_ && w.wanted;
        // Gate the content, not the window: contentItem.visible does not
        // reliably repaint when re-shown, and an ungated hidden window commits
        // frames that make KWin stretch stale buffers during a resize. The gate
        // is shell-owned so a plugin `visible:` binding cannot re-assert itself,
        // but plugin QML can still reach and re-show it (see Win::gate).
        if (w.gate) w.gate->setVisible(eff);
        // NOT wc_->setInputEnabled: input and shape are the same QWindow::setMask
        // write, so one place has to compose them. See applyMask.
        applyMask(w);
    }
    // ONE KWin execution for the whole set. Without KWin this returns
    // false and the windows keep whatever opacity they have — they still show
    // nothing, because the content above is gated and the surface is
    // transparent; what is lost is only the atomicity of the swap.
    if (wc_ && applyOpacity) wc_->setWindowOpacities(opacityEntries());
    // Regardless of applyOpacity, which only decides who issues the KWin call;
    // Main.qml's compact flip passes false and the FFT must still follow it.
    syncSpectrum();
}

// See the header for why the shell, not the plugin, is the one asking.
void PluginWindowHost::syncSpectrum() {
    if (!spectrum_) return;
    bool want = false;
    for (const QString& id : std::as_const(order_)) {
        const auto it = wins_.constFind(id);
        // Same predicate applyState just used for the silence gate: a window
        // that paints nothing holds nothing.
        if (it != wins_.cend() && it->win && active_ && it->wanted) { want = true; break; }
    }
    spectrum_->request(spectrumOwner_, want);
}

// Desired position for `id` given its snapTo target; `snapped` reports whether
// magnetism engaged, which marks the window docked. Positions come from posOf().
QPoint PluginWindowHost::snapTarget(const QString& id, bool* snapped, Dock* edge) const {
    if (snapped) *snapped = false;
    if (edge) *edge = Dock::None;
    const auto it = wins_.constFind(id);
    if (it == wins_.cend() || !it->win) return QPoint();
    const QPoint cur = posOf(*it);
    const QString tid = it->decl.value(QStringLiteral("snapTo")).toString();
    if (tid.isEmpty() || tid == id || snapDistance_ <= 0) return cur;
    const auto tt = wins_.constFind(tid);
    if (tt == wins_.cend() || !tt->win) return cur;

    // dockSize, not the raw geometry: a hidden target spends no chain, and the
    // candidate offered to magnetism has to be the SAME point reflowDocked
    // would re-seat this window to. Two readings there is a window that snaps
    // flush and is then moved somewhere else by the next reflow.
    const QRect t(posOf(*tt), dockSize(*tt));
    const QSize sz = dockSize(*it);
    for (const Dock e : {Dock::Below, Dock::Above, Dock::Right, Dock::Left}) {
        const QPoint c = dockPoint(t, e, sz);
        if (qAbs(c.x() - cur.x()) <= snapDistance_ && qAbs(c.y() - cur.y()) <= snapDistance_) {
            if (snapped) *snapped = true;
            if (edge) *edge = e;
            return c;
        }
    }
    return cur;
}

// Re-seat everything docked to `id` after its size changed (a resize or shade
// moves no position, so applySnap finds nothing). Iterative and bounded like
// applySnap; one KWin execution for the whole cascade.
void PluginWindowHost::reflowDocked(const QString& id) {
    if (!wins_.contains(id)) return;
    QVariantList moves;
    QSet<QString> seen{id};
    QStringList work{id};
    int budget = order_.size() + 1;
    while (!work.isEmpty() && budget-- > 0) {
        const QString parent = work.takeFirst();
        const Win& p = wins_[parent];
        if (!p.win) continue;
        const QRect pr(posOf(p), dockSize(p));
        for (const QString& cid : order_) {
            if (seen.contains(cid)) continue;
            Win& c = wins_[cid];
            if (!c.win || !c.docked || c.edge == Dock::None
                || c.decl.value(QStringLiteral("snapTo")).toString() != parent) continue;
            seen.insert(cid);
            moveWindow(c, dockPoint(pr, c.edge, dockSize(c)), moves);
            work << cid;
        }
    }
    // Every window this pass touched is where it now is, so a change
    // notification arriving late cannot be read as a drag from a stale base —
    // the same bookkeeping applySnap ends with, and for the same reason.
    for (const QString& wid : order_)
        if (wins_[wid].win) wins_[wid].lastPos = posOf(wins_[wid]);
    if (!moves.isEmpty() && wc_) wc_->moveWindows(moves);   // one KWin execution
    syncWindowGlue();
}

void PluginWindowHost::reflowLater(const QString& id) {
    if (!pendingReflow_.contains(id)) pendingReflow_ << id;
    if (resettle_ && !resettle_->isActive()) resettle_->start();
}

void PluginWindowHost::moveWindow(Win& w, const QPoint& to, QVariantList& moves) {
    if (!w.win || posOf(w) == to) return;
    qCDebug(loggerWindows) << "MOVE" << w.title << posOf(w) << "->" << to;
    QScopedValueRollback<bool> guard(moving_, true);
    // The real move on X11/Windows. On Wayland it does nothing and position()
    // stays stale; KWin moves the window by caption, and `lastPos`/`pos` are
    // this class's only record of where it is.
    w.win->setPosition(to);
    moves << QVariantMap{{QStringLiteral("title"), w.title},
                         {QStringLiteral("x"), to.x()}, {QStringLiteral("y"), to.y()}};
    w.lastPos = w.pos = to;
    w.placedByUs = true;
    notifyLater(w.id);
}

// A completed USER move of one watched window, as KWin reports it. This is the
// whole of what makes snapping live on Wayland: there is no xdg_toplevel
// position event, so `moved` above never fires for a drag and melo would
// otherwise never learn the window is somewhere new.
void PluginWindowHost::onWindowGeometry(const QString& caption, int x, int y) {
    QString id;
    for (const QString& k : order_)
        if (wins_.value(k).title == caption) { id = k; break; }
    // Not one of ours. The watcher is installed with this host's captions only,
    // but the signal is the WindowController's and carries whatever it is told.
    if (id.isEmpty()) return;
    // KWin reports a watched window when its interactive move OR resize ends,
    // and that is the only notice either finished. Released here rather than
    // further down because a resize lands on the "position unchanged" path,
    // which returns early.
    if (id == holdId_) endHold();
    Win& w = wins_[id];
    if (!w.win) return;
    const QPoint at(x, y);

    // A window's first report is the watcher arming, not a user drag: adopt it
    // into `pos` and `lastPos` so no delta is derived from it.
    if (!w.kwinOwnsPos) {
        w.kwinOwnsPos = true;
        // Unless melo already placed it: placement may land after the arm-time
        // report, and adopting a stale report would put this window on a
        // different base from its siblings.
        if (!w.placedByUs) {
            w.lastPos = w.pos = at;
            notifyLater(id);
        }
        return;
    }

    const bool finishingMove = w.userMoving;
    qCDebug(loggerWindows) << "REPORT" << id << "at" << at << "known" << w.pos
                           << "last" << w.lastPos << "placedByUs" << w.placedByUs
                           << "userMoving" << w.userMoving
                           << "size" << (w.win ? w.win->size() : QSize());
    w.userMoving = false;
    // The size this window started the move on, put back EXACTLY. See
    // Win::sizeAtGrab for why it is not re-derived from the resize grid.
    // A shade toggle mid-drag is a size change the user asked for, so it wins.
    auto restoreSizeAfterMove = [&] {
        if (!finishingMove || w.shaded || !w.sizeAtGrab.isValid()) return;
        const QSize cur(w.win->width(), w.win->height());
        if (cur != w.sizeAtGrab) w.win->resize(w.sizeAtGrab);
        w.sizeAtGrab = QSize();
    };

    // The compositor echoing our own move, off by up to a device pixel of
    // rounding; treated as a drag it would snap back and forth on settle. A
    // report far from lastPos is a user move; startDrag clears placedByUs so a
    // grab racing the echo is kept.
    if (w.placedByUs) {
        w.placedByUs = false;
        const QPoint asked = w.lastPos;
        const bool echo = qAbs(at.x() - asked.x()) <= 2 && qAbs(at.y() - asked.y()) <= 2;
        w.pos = at;
        notifyLater(id);
        if (echo) {
            w.lastPos = at;
            restoreSizeAfterMove();
            return;
        }
        // Far from where we placed it: the user moved this window. Fall through.
    } else if (w.pos == at) {
        restoreSizeAfterMove();
        return;    // a resize, or a drag that ended where it began
    } else {
        w.pos = at;
        notifyLater(id);
    }

    restoreSizeAfterMove();
    if (moving_) return;        // our own move; applySnap guards on this too
    // Finished already means settled. A 120ms timer here is not debounce —
    // it is a pause after the user has let go, then a jump of every attached
    // window onto the group. The X11 door (xChanged) still uses settle_.
    applySnap(id);
}

// Magnetism for the window the user moved; windows docked to it follow by the
// same delta. Terminates on any snapTo graph, cycles included: iterative,
// `seen` admits each window once, and a budget of order_.size() + 1.
//
// Rewriting every window's lastPos at the end is what stops a move feeding
// back: a late xChanged/yChanged (after `moving_` unwinds) then yields a null
// delta and moves nothing.
void PluginWindowHost::applySnap(const QString& movedId) {
    if (moving_) return;
    auto it = wins_.find(movedId);
    if (it == wins_.end() || !it->win) return;

    QVariantList moves;
    // Where the compositor says this window ended up, BEFORE magnetism gets a
    // say. The glue placed every follower relative to exactly this point.
    const QPoint reported = posOf(*it);
    const QHash<QString, QPoint> carried = glueLinks_.value(movedId);
    const QPoint before = it->lastPos;
    bool snapped = false;
    Dock edge = Dock::None;
    const QPoint want = snapTarget(movedId, &snapped, &edge);
    // The re-dock decision, where a panel the user pulled away gets pulled back.
    // `snapDistance_` is the manifest's snap.distance times the scale, so at
    // 1.3 a 10px magnet is 13px of travel the user cannot keep.
    qCDebug(loggerWindows) << "SNAP" << movedId << "at" << posOf(*it)
                           << "-> want" << want << "snapped" << snapped
                           << "wasDocked" << it->docked
                           << "dist" << snapDistance_
                           << "delta" << (want - posOf(*it));
    it->docked = snapped;
    it->edge = edge;
    if (want != posOf(*it)) moveWindow(*it, want, moves);
    const QPoint delta = posOf(*it) - before;

    if (!delta.isNull()) {
        QSet<QString> seen{movedId};
        QStringList work{movedId};
        int budget = order_.size() + 1;
        while (!work.isEmpty() && budget-- > 0) {
            const QString parent = work.takeFirst();
            for (const QString& cid : order_) {
                if (seen.contains(cid)) continue;
                Win& c = wins_[cid];
                if (!c.win || !c.docked
                    || c.decl.value(QStringLiteral("snapTo")).toString() != parent) continue;
                seen.insert(cid);
                const QPoint target = posOf(c) + delta;
                // ALREADY THERE, compositor-side. Only true when magnetism did
                // not move the leader off the reported point — if it did, the
                // glue's placement is stale by the snap and the move is real.
                if (carried.contains(cid) && target == reported + carried.value(cid)) {
                    qCDebug(loggerWindows) << "CARRIED" << c.title << "->" << target
                                           << "(glue already placed it)";
                    c.lastPos = c.pos = target;
                    notifyLater(cid);
                } else {
                    moveWindow(c, target, moves);
                }
                work << cid;
            }
        }
    }
    for (const QString& id : order_)
        if (wins_[id].win) wins_[id].lastPos = posOf(wins_[id]);
    if (!moves.isEmpty() && wc_) wc_->moveWindows(moves);   // one KWin execution
    syncWindowGlue();
}

// One pass in declaration order: the primary goes to the main window's
// position, and a window whose snapTo target is already placed docks below it.
// A forward reference keeps the compositor's placement, so this cannot loop.
void PluginWindowHost::placeInitial(bool force) {
    if (order_.isEmpty()) return;
    // On Wayland only KWin knows the main window's position. Ask for a report
    // on demand, with a bounded wait: the installed watcher reports only after
    // a user move, so a host built later would wait forever.
    if (!force && wc_ && wc_->kwinAvailable() && !haveMainPos_) {
        placeWanted_ = true;
        if (!wc_->reportMainGeometry()) { placeInitial(true); return; }
        QTimer::singleShot(1500, this, [this] {
            if (!placeWanted_) return;      // the report landed and placed the group
            placeWanted_ = false;
            placeInitial(true);
        });
        return;
    }
    // All or nothing: without a KWin report the base is (0,0), which the
    // primary's stale lastPos matches, so only the secondaries would move and
    // the group would split and be marked docked while apart. Place nothing.
    const bool clientKnowsPositions = !(wc_ && wc_->kwinAvailable());
    if (!haveMainPos_ && !clientKnowsPositions) {
        std::fprintf(stderr, "[melo] plugin %s: no KWin geometry report — plugin windows keep "
                             "the compositor's placement (not docked)\n",
                     bridge_ ? bridge_->pluginId().toUtf8().constData() : "?");
        return;
    }
    const QPoint base = haveMainPos_ ? mainPos_
                      : (transientParent_ ? transientParent_->position() : QPoint());
    QVariantList moves;
    // Intended positions, never read back from QWindow: on Wayland position()
    // does not follow setPosition().
    QHash<QString, QPoint> at;
    QSet<QString> placed;
    at.insert(primaryId_, base);
    moveWindow(wins_[primaryId_], base, moves);
    placed.insert(primaryId_);
    for (const QString& id : order_) {
        if (placed.contains(id)) continue;
        Win& w = wins_[id];
        const QString tid = w.decl.value(QStringLiteral("snapTo")).toString();
        if (!placed.contains(tid)) continue;
        // Size is client-owned and trustworthy. dockPoint/dockSize, so the group
        // opens on the same chain a reflow keeps (a hidden window spends no height).
        const QPoint to = dockPoint(QRect(at.value(tid), dockSize(wins_[tid])),
                                    Dock::Below, dockSize(w));
        at.insert(id, to);
        moveWindow(w, to, moves);
        qCDebug(loggerWindows) << "DOCK(initial)" << id << "-> docked=true";
        w.docked = true;
        w.edge = Dock::Below;   // the only side placeInitial ever docks on
        placed.insert(id);
    }
    for (const QString& id : order_)
        if (wins_[id].win) wins_[id].lastPos = at.contains(id) ? at.value(id)
                                                               : posOf(wins_[id]);
    if (!moves.isEmpty() && wc_) wc_->moveWindows(moves);
    syncWindowGlue();
}

// Connected components of the dock graph, in declaration order (see the
// header). Edges are walked both ways, so a window leaving takes everything
// docked to it without a special case.
QVector<PluginWindowHost::Group> PluginWindowHost::windowGroups() const {
    QHash<QString, QStringList> adjacency;
    for (const QString& id : order_) {
        const Win& w = wins_.value(id);
        if (!w.win || !w.docked) continue;
        const QString target = w.decl.value(QStringLiteral("snapTo")).toString();
        if (target.isEmpty() || target == id || !wins_.contains(target)) continue;
        adjacency[id] << target;
        adjacency[target] << id;
    }

    QVector<Group> groups;
    QSet<QString> seen;
    for (const QString& start : order_) {
        if (seen.contains(start) || !wins_.value(start).win) continue;
        // Collect the component, then order it by `order_` so a group's panels
        // read in declaration order however the user assembled them.
        QSet<QString> member;
        QStringList work{start};
        seen.insert(start);
        member.insert(start);
        while (!work.isEmpty()) {
            const QString cur = work.takeFirst();
            for (const QString& next : adjacency.value(cur)) {
                if (member.contains(next) || !wins_.value(next).win) continue;
                member.insert(next);
                seen.insert(next);
                work << next;
            }
        }

        Group g;
        for (const QString& id : order_) if (member.contains(id)) g.ids << id;

        // The box is measured from SHOWN panels only (dockSize's rule). A group
        // with nothing shown has no box, and its origin falls back to the
        // primary member's position so it still has somewhere to be.
        QRect box;
        for (const QString& id : g.ids) {
            const Win& w = wins_.value(id);
            const QSize extent = dockSize(w);
            if (extent.isEmpty()) continue;
            box = box.isNull() ? QRect(posOf(w), extent) : box.united(QRect(posOf(w), extent));
        }
        g.origin = box.isNull() ? posOf(wins_.value(g.ids.first())) : box.topLeft();
        g.size = box.isNull() ? QSize() : box.size();
        for (const QString& id : g.ids) g.offset.insert(id, posOf(wins_.value(id)) - g.origin);
        groups << g;
    }
    return groups;
}

void PluginWindowHost::applyGroupMask(const Group& g) {
    if (g.ids.isEmpty()) return;
    Win& host = wins_[g.ids.first()];
    if (!host.win) return;

    QRegion want;
    bool anyEffective = false;
    bool everyShapeIsPlain = true;
    for (const QString& id : g.ids) {
        const Win& w = wins_.value(id);
        if (!active_ || !w.wanted) continue;      // the silence rule, per panel
        anyEffective = true;
        const QPoint at = g.offset.value(id);
        if (w.shape.isEmpty()) want += QRect(at, w.size);
        else { everyShapeIsPlain = false; want += w.shape.translated(at); }
    }
    // Nothing to show: the same one-pixel offscreen mask a silenced window
    // gets. One plain panel: no mask at all.
    const QRegion mask = !anyEffective ? QRegion(-100, -100, 1, 1)
                       : (everyShapeIsPlain && g.ids.size() == 1) ? QRegion()
                       : want;
    if (host.win->mask() != mask) host.win->setMask(mask);
}

void PluginWindowHost::applyMasks() {
    for (const Group& g : windowGroups()) applyGroupMask(g);
}

// One mapped window per group. See the header.
void PluginWindowHost::applyGroups() {
    for (const QString& id : order_) wins_[id].hostsPanels = 0;

    for (const Group& g : windowGroups()) {
        const QString hostId = g.ids.first();
        Win& host = wins_[hostId];
        if (!host.win) continue;
        // BEFORE the resize below, so the funnel's guard is already true when
        // that resize calls straight back into it.
        host.hostsPanels = g.ids.size();
        QQuickItem* into = host.win->contentItem();

        for (const QString& id : g.ids) {
            Win& w = wins_[id];
            if (!w.win || !w.gate) continue;
            if (w.gate->parentItem() != into) w.gate->setParentItem(into);
            w.gate->setPosition(QPointF(g.offset.value(id)));
            w.gate->setSize(QSizeF(w.size));
            // The plugin's root inside the gate, scaled exactly as the resize
            // funnel does it — the gate is shell-owned, the root is not.
            const QSizeF logical(w.size.width() / scale_, w.size.height() / scale_);
            for (QQuickItem* child : w.gate->childItems()) {
                child->setScale(scale_);
                child->setTransformOrigin(QQuickItem::TopLeft);
                child->setSize(logical);
            }
            // UNMAP: a toplevel that is not mapped is not a snap candidate, so the compositor has
            // nothing to weld the dragged window to.
            if (id != hostId && w.win->isVisible()) w.win->setVisible(false);
        }

        if (!g.size.isEmpty() && host.win->size() != g.size) host.win->resize(g.size);
        if (!host.win->isVisible()) host.win->setVisible(true);
        applyGroupMask(g);
    }
}

QStringList PluginWindowHost::windowTitles() const {
    QStringList titles;
    for (const QString& id : order_) titles << wins_.value(id).title;
    return titles;
}

QRect PluginWindowHost::pluginWindowRect(const QString& id) const {
    const auto it = wins_.constFind(id);
    if (it == wins_.cend() || !it->win) return {};
    // posOf, not position(): what a plugin reads as MeloUi.window.<id>.x/y must
    // be where the window IS. On Wayland position() answers 0,0 forever.
    return QRect(posOf(*it), it->size);
}

bool PluginWindowHost::pluginWindowShown(const QString& id) const {
    const auto it = wins_.constFind(id);
    return it != wins_.cend() && it->wanted;
}

bool PluginWindowHost::pluginWindowShaded(const QString& id) const {
    const auto it = wins_.constFind(id);
    return it != wins_.cend() && it->shaded;
}

// Through setPluginWindowShown, not by touching `wanted` directly, so a dismiss
// leaves the same bookkeeping behind as five separate clicks on the skin's own
// buttons: the chain reflows, the facades notify, and the FFT is released.
void PluginWindowHost::dismissWindows() {
    for (const QString& id : order_) setPluginWindowShown(id, false);
}

void PluginWindowHost::setPluginWindowShown(const QString& id, bool on) {
    auto it = wins_.find(id);
    if (it == wins_.end() || it->wanted == on) return;
    it->wanted = on;
    // Showing or hiding changes this window's dockSize, and no position changed
    // for applySnap to see, so reflow. Rooted at the snapTo target, not `id`:
    // reflowDocked moves only children, and an Above or Left dock moves `id`
    // itself by its own size (aWindowDockedAboveItsTargetMovesForItsOwnVisibility).
    // Before the opacity call, so the window appears already in place.
    const QString tid = it->decl.value(QStringLiteral("snapTo")).toString();
    reflowDocked(wins_.contains(tid) ? tid : id);
    applyState();               // one atomic opacity call for the whole set
    notifyLater(id);
}

void PluginWindowHost::togglePluginWindowShade(const QString& id) {
    auto it = wins_.find(id);
    if (it == wins_.end() || !it->win) return;
    const int shadeH = it->decl.value(QStringLiteral("shade")).toObject()
                              .value(QStringLiteral("height")).toInt();
    if (shadeH <= 0) return;    // this window declared no shade mode
    // The shape is not re-derived: a skin's shaded mode has its own outline
    // (region.txt has a section per mode), so the plugin calls setShape again.
    // Pinned by aResizeDoesNotReDeriveTheShape.
    //
    // The flag is set before the resize: the shade height is off the resize
    // grid, and the quantiser and limits must both see it. Tests cover only the
    // limits (shadingAResizableWindowKeepsTheShadeHeight); the quantiser order
    // matters where window-system events are synchronous (Windows), so do not
    // reorder on the strength of a green suite here.
    const bool toShade = !it->shaded;
    if (toShade) it->fullHeight = it->size.height();
    it->shaded = toShade;
    applySizeLimits(*it);
    const QSize shadeTarget(it->size.width(),
                            toShade ? shadeH
                                    : (it->fullHeight > 0
                                           ? it->fullHeight
                                           : it->decl.value(QStringLiteral("height")).toInt()));
    // BOTH, and not one via the other. Win::size is the panel's size and this
    // is where it changes; leaving it to the resize signal would make a shaded
    // panel spend its OLD height in the chain, so the group below it would
    // never move up.
    it->size = shadeTarget;
    it->win->resize(shadeTarget);
    // A shade toggle keeps the top edge fixed; on Wayland the compositor owns
    // the resize anchor, so melo restates the position. Not via moveWindow(),
    // which skips a target equal to its own record; placedByUs marks the echo
    // as melo's own rather than a user drag.
    if (wc_) {
        const QPoint at = posOf(*it);
        it->placedByUs = true;
        it->lastPos = it->pos = at;
        wc_->moveWindows({QVariantMap{{QStringLiteral("title"), it->title},
                                      {QStringLiteral("x"), at.x()},
                                      {QStringLiteral("y"), at.y()}}});
    }
    notifyLater(id);
    // Windows docked below were flush against the old bottom edge; no position
    // changed, so only a reflow re-seats them.
    reflowDocked(id);
}

// --- window shaping (region.txt) -------------------------------------------
//
// kMaxPolygons / kMaxPointsPerPolygon bound how much of the argument is parsed.
// kCoordLimit is the native range of an X11 region and a wl_region, not the
// window size: real region.txt files run past their window.
// kShapeWorkBudget bounds scan conversion, the real cost: QRegion(QPolygon)
// emits up to ceil(points/2) rects per scanline, so cost follows vertical span,
// not point count. The worst shape 32k admits takes ~22 ms
// (theWorstCaseTheCapsPermitStaysInBudget measures it). It bounds what a shape
// costs, not what a hostile plugin can do.
//
// Over-budget polygons are dropped, never clamped (a moved corner is a
// different shape), one polygon at a time, and counted on stderr. The estimate
// assumes the worst and overcharges smooth outlines (a 1000-point outline over
// 116 rows is dropped); classic skins are quads, costing 1 each through the
// rectangle shortcut. If a detailed outline loses polygons, fix the estimate
// (count edge crossings per scanline), not the budget.
static constexpr int kMaxPolygons = 512;
static constexpr int kMaxPointsPerPolygon = 8192;
static constexpr int kCoordLimit = 32767;
static constexpr long long kShapeWorkBudget = 32 * 1024;

// An axis-aligned rectangle (every quad in a real region.txt) costs one rect,
// not one per scanline, which keeps the budget tight. Matches the scan
// converter: right and bottom edges are exclusive, as region.txt means them.
//
// Three tests, each rejecting a shape the other two accept; without any one,
// a non-rectangle is silently served as a rectangle:
//   (a) every corner on the bounding box: rejects an interior corner;
//   (b) every edge axis-parallel: rejects a bowtie;
//   (c) all four distinct corners present: rejects a spike such as
//       (0,0) (10,0) (10,7) (10,0), whose QRegion is empty.
// theRectangleShortcutAgreesWithTheScanConverter carries the case.
static bool shapeAxisAlignedRect(const QPolygon& poly, QRect* out) {
    if (poly.size() != 4) return false;
    const QRect b = poly.boundingRect();
    if (b.width() < 2 || b.height() < 2) return false;   // degenerate: let the scan converter say so
    // (a)
    for (const QPoint& p : poly)
        if ((p.x() != b.left() && p.x() != b.right())
            || (p.y() != b.top() && p.y() != b.bottom())) return false;
    // (b) exactly one coordinate changes per edge — both, or neither, is not a
    // rectangle traversal
    for (int i = 0; i < 4; ++i) {
        const QPoint a = poly.at(i), c = poly.at((i + 1) % 4);
        if ((a.x() != c.x()) == (a.y() != c.y())) return false;
    }
    // (c) all four corners actually present. Without this a repeated corner
    // passes (a) and (b) and a spike is served as a filled rectangle.
    int seen = 0;
    for (const QPoint& p : poly)
        seen |= 1 << ((p.x() == b.right() ? 1 : 0) | (p.y() == b.bottom() ? 2 : 0));
    if (seen != 0b1111) return false;

    *out = QRect(b.left(), b.top(), b.right() - b.left(), b.bottom() - b.top());
    return true;
}

// An upper bound on the rects QRegion(QPolygon) can emit for this polygon: at
// most one span per edge-crossing pair, on every scanline it covers.
static long long shapeWork(const QPolygon& poly) {
    QRect r;
    if (shapeAxisAlignedRect(poly, &r)) return 1;
    return (long long)((poly.size() + 1) / 2) * qMax(1, poly.boundingRect().height());
}

// One coordinate. qIsFinite FIRST, not qBound: qBound(-32767.0, NaN, 32767.0)
// returns the LOW bound rather than rejecting, so a NaN corner would silently
// become a real one at the far edge of the shape instead of invalidating its
// polygon. (std::clamp differs again and returns the NaN.) Both are wrong here.
static bool shapeCoordinate(const QVariant& v, int* out) {
    bool ok = false;
    const double d = v.toDouble(&ok);
    if (!ok || !qIsFinite(d) || d < -kCoordLimit || d > kCoordLimit) return false;
    *out = int(d);
    return true;
}

// A point in any of the three shapes a plugin can reasonably arrive at: a
// {x,y} object, a two-element [x,y] array, or a real QPoint/QPointF.
static bool shapePoint(const QVariant& v, QPoint* out) {
    switch (v.metaType().id()) {
    case QMetaType::QPoint:
    case QMetaType::QPointF: {
        const QPointF p = v.toPointF();
        return shapeCoordinate(p.x(), &out->rx()) && shapeCoordinate(p.y(), &out->ry());
    }
    case QMetaType::QVariantMap: {
        const QVariantMap m = v.toMap();
        const auto x = m.constFind(QStringLiteral("x")), y = m.constFind(QStringLiteral("y"));
        return x != m.cend() && y != m.cend()
            && shapeCoordinate(*x, &out->rx()) && shapeCoordinate(*y, &out->ry());
    }
    case QMetaType::QVariantList: {
        const QVariantList l = v.toList();
        return l.size() == 2
            && shapeCoordinate(l.at(0), &out->rx()) && shapeCoordinate(l.at(1), &out->ry());
    }
    default:
        return false;
    }
}

// One polygon, whole or not at all: dropping only a malformed point would
// re-link the outline into a different shape and report success.
static bool shapePolygon(const QVariant& v, QPolygon* out) {
    if (v.metaType().id() != QMetaType::QVariantList) return false;
    const QVariantList raw = v.toList();
    if (raw.isEmpty()) return false;

    QPolygon poly;
    QPoint p;
    if (shapePoint(raw.first(), &p)) {              // a list of POINTS
        if (raw.size() > kMaxPointsPerPolygon) return false;
        poly.reserve(int(raw.size()));
        for (const QVariant& e : raw) {
            if (!shapePoint(e, &p)) return false;
            poly << p;
        }
    } else {                                        // a FLAT coordinate list
        // What a region.txt `PointList=5,0 270,0 …` line parses to. An odd
        // count is a coordinate without its partner: unusable, not roundable.
        if (raw.size() % 2 != 0) return false;
        if (raw.size() / 2 > kMaxPointsPerPolygon) return false;
        poly.reserve(int(raw.size()) / 2);
        for (qsizetype i = 0; i < raw.size(); i += 2) {
            if (!shapeCoordinate(raw.at(i), &p.rx())
                || !shapeCoordinate(raw.at(i + 1), &p.ry())) return false;
            poly << p;
        }
    }
    // Fewer than three corners enclose nothing. QRegion would accept them and
    // produce an empty region, which is the same OUTCOME — saying it here is
    // what makes "one point" a named rejection that gets counted and reported,
    // instead of a silent no-op indistinguishable from success.
    if (poly.size() < 3) return false;
    *out = poly;
    return true;
}

QRegion PluginWindowHost::shapeRegion(const QVariantList& polygons, int* dropped) {
    int bad = 0;
    // The excess is DROPPED, not an error: refusing the whole shape over the
    // 513th polygon would turn a merely greedy skin into a rectangular one.
    const int n = int(qMin(polygons.size(), qsizetype(kMaxPolygons)));
    bad += int(polygons.size()) - n;

    QRegion region;
    long long work = 0;
    for (int i = 0; i < n; ++i) {
        QPolygon poly;
        if (!shapePolygon(polygons.at(i), &poly)) { ++bad; continue; }
        // Charged BEFORE the conversion, from the parsed corners: the blow-up
        // happens inside QRegion's constructor, so a check afterwards would be
        // a check after the cost has already been paid.
        const long long cost = shapeWork(poly);
        if (work + cost > kShapeWorkBudget) { ++bad; continue; }
        work += cost;
        QRect r;
        if (shapeAxisAlignedRect(poly, &r)) region += QRegion(r);   // identical, without the scan
        else region += QRegion(poly);
    }
    if (dropped) *dropped = bad;
    return region;
}

void PluginWindowHost::setPluginWindowShape(const QString& id, const QVariantList& polygons) {
    auto it = wins_.find(id);
    // The plugin cannot choose the id (MeloUiWindow stamps its own); this
    // lookup is a second gate that fails closed for any other route.
    if (it == wins_.end() || !it->win) return;

    int dropped = 0;
    it->logicalShape = shapeRegion(polygons, &dropped);
    it->shape = scaledRegion(it->logicalShape, scale_);
    if (dropped > 0)
        std::fprintf(stderr, "[melo] plugin %s: window %s: %d of %lld shape polygons ignored "
                             "(the rest still apply)\n",
                     bridge_ ? bridge_->pluginId().toUtf8().constData() : "?",
                     id.toUtf8().constData(), dropped, (long long)polygons.size());
    applyMask(*it);
}

void PluginWindowHost::setScale(double requested) {
    if (!qIsFinite(requested)) return;
    const double next = qBound(0.5, requested, 4.0);
    if (qFuzzyCompare(next, scale_)) return;
    const double old = scale_;
    scale_ = next;
    snapDistance_ = qRound(baseSnapDistance_ * scale_);

    for (const QString& id : order_) {
        Win& w = wins_[id];
        if (!w.win) continue;
        const QSizeF logicalCurrent(w.size.width() / old, w.size.height() / old);
        const double logicalFullHeight = w.fullHeight / old;
        w.decl = scaledWindowDecl(w.logicalDecl, scale_);
        w.fullHeight = qMax(1, qRound(logicalFullHeight * scale_));

        QSize target(qMax(1, qRound(logicalCurrent.width() * scale_)),
                     qMax(1, qRound(logicalCurrent.height() * scale_)));
        if (w.shaded) {
            target.setWidth(w.decl.value(QStringLiteral("width")).toInt());
            target.setHeight(w.decl.value(QStringLiteral("shade")).toObject()
                                  .value(QStringLiteral("height")).toInt());
        } else {
            target = quantiseAtScale(w.logicalDecl, target, scale_);
        }

        w.win->setMinimumSize(QSize(1, 1));
        w.win->setMaximumSize(QSize(kMaxWindowEdge, kMaxWindowEdge));
        w.size = target;
        w.win->resize(target);
        applySizeLimits(w);

        const QSizeF physical(w.size.width(), w.size.height());
        if (w.gate) {
            w.gate->setSize(physical);
            const QSizeF logical(physical.width() / scale_, physical.height() / scale_);
            for (QQuickItem* child : w.gate->childItems()) {
                child->setScale(scale_);
                child->setTransformOrigin(QQuickItem::TopLeft);
                child->setSize(logical);
            }
        }
        w.shape = scaledRegion(w.logicalShape, scale_);
        applyMask(w);
        notifyLater(id);
    }
    if (!primaryId_.isEmpty()) reflowDocked(primaryId_);
}

// Shape and silence are both QWindow::setMask, which writes the whole mask, so
// this host composes them for its windows and never calls setInputEnabled:
// that would wipe a skin's shape on the next show/hide, and a shape applied
// alone would make a silenced window clickable.
//
// setMask is input-only on Wayland (Qt 6.10.3 + KWin: set_input_region, no
// clip, applied at the next commit), bounding-shape-only on X11 (pixels
// clipped, input unshaped), and a clip on Windows. Skins supply sprite alpha
// and setShape both (docs/plugins.md).
void PluginWindowHost::applyMask(Win& w) {
    if (!w.win) return;
    const bool eff = active_ && w.wanted;
    // Silenced: the off-surface region setInputEnabled(false) uses; keep them in
    // step. QRegion has no empty-but-set state, so a zero-area shape means
    // rectangular rather than unclickable.
    const QRegion want = eff ? w.shape : QRegion(-100, -100, 1, 1);
    // applyState() runs for the whole set on every show/hide and every
    // setActive, so most calls here change nothing. QWindow::mask() IS the
    // applied value, so comparing against it needs no bookkeeping of our own.
    if (w.win->mask() == want) return;
    w.win->setMask(want);
}

void PluginWindowHost::startPluginWindowDrag(const QString& id) {
    auto it = wins_.find(id);
    if (it == wins_.end() || !it->win) return;
    // A window nobody can see must not be draggable: a silenced host's windows
    // are transparent and click-through, and a drag there would move something
    // invisible under the user.
    if (!active_ || !it->wanted) return;
    // Before startSystemMove, so a configure arriving with the grab sees the
    // flag. placedByUs is cleared so the Finished report counts as a user move.
    it->userMoving = true;
    it->placedByUs = false;
    it->sizeAtGrab = it->size;
    qCDebug(loggerWindows) << "GRAB" << id << "at" << posOf(*it) << "size" << it->sizeAtGrab;
    it->win->startSystemMove();
}

// The user's hand on the resize grip, handed to the compositor. See
// MeloUiWindow::startResize for why this is the only route to a new size and
// why it carries none.
void PluginWindowHost::startPluginWindowResize(const QString& id) {
    const Qt::Edges edges = resizeGrabEdges(id);   // the gates, and what they allow
    if (!edges) return;
    auto it = wins_.find(id);
    if (it == wins_.end() || !it->win) return;
    beginHold(id);           // before the grab; see beginHold
    it->win->startSystemResize(edges);
}
