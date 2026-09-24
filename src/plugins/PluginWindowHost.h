#pragma once
#include "MeloUi.h"

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QPoint>
#include <QPointer>
#include <QRect>
#include <QRegion>
#include <QStringList>
#include <QVariantList>

class QQuickItem;
class QQuickWindow;
class QTimer;
class QWindow;
class PluginUiHost;
class SpectrumSource;
class WindowController;

// Creates and owns the windows a ui plugin declares. The plugin never sees a
// Window type, so melo enforces the window invariants:
//   - transient children of the main window, so the group takes one taskbar
//     entry (Plasma's task manager excludes transients).
//   - content is gated visible:false while `!active_ || !wanted`: a sibling
//     window committing frames makes KWin stretch-fit stale buffers during an
//     interactive resize. Windows stay mapped for life; unmapping fires WM
//     open/close animations and loses the position.
//   - opacity for every window is set in one KWin call; splitting it shows a
//     1-frame gap or double.
// Snapping is computed here from the plugin's snapTo, so a plugin cannot
// produce geometry that breaks the above.
class PluginWindowHost : public QObject, public PluginWindowBackend {
    Q_OBJECT
public:
    // `spectrum` is deliberately NOT defaulted: it is the shell handing this
    // host the right to ask for the FFT, and a default would let a future call
    // site drop that silently and leave a plugin analyser dark. Tests that do
    // not exercise the FFT pass nullptr and say so.
    PluginWindowHost(PluginUiHost* ui, MeloUi* bridge, QWindow* transientParent,
                     WindowController* wc, SpectrumSource* spectrum,
                     QObject* parent = nullptr);
    ~PluginWindowHost() override;

    // One window per ui.windows[] entry. All windows and their facades exist
    // before any window's QML is instantiated, so a plugin can read
    // MeloUi.window from its own Component.onCompleted.
    bool build(const QJsonObject& uiBlock, double scale = 1.0);
    // Shell-only target of MeloUi.app.setScale(). The value is clamped; all
    // windows, transforms, masks, resize increments and snap distance update
    // as one operation.
    void setScale(double scale);

    // Host-level paint switch: silence gating + input, then the opacity call.
    // applyOpacity=false leaves opacity to the caller: Main.qml folds it into its
    // compact-flip KWin call, since a second call shows a 1-frame gap or double.
    Q_INVOKABLE void setActive(bool on, bool applyOpacity = true);
    void setFrozen(bool on);
    // Drops QEvent::UpdateRequest for plugin windows while frozen, which is how
    // a surface holds its last frame instead of vanishing. See setFrozen.
    bool eventFilter(QObject* obj, QEvent* ev) override;
    // This host's opacity entries in setWindowOpacities' shape, for Main.qml to
    // fold into its compact-flip call. Plugin entries stay 1 while the host is live.
    Q_INVOKABLE QVariantList opacityEntries() const;

    // What MeloUi.app.exitMiniMode() means. Compact is first-party, so there is
    // no mode for a plugin to leave, but a skin's close/eject button must still
    // do something: the shell DISMISSES the plugin's own windows. The host stays live, so a command or a gesture
    // brings the group straight back on the layout it was dismissed from.
    Q_INVOKABLE void dismissWindows();

    // One QWindow's worth of panels: a connected component of the dock graph,
    // its bounding box, and each member's offset in it. Computed on demand so no
    // cached copy can go stale. A hidden panel stays a member but takes no
    // extent, as in dockSize.
    struct Group {
        QStringList ids;                  // declaration order, as `order_`
        QPoint origin;                    // screen position of the box
        QSize size;                       // the box; empty when nothing is shown
        QHash<QString, QPoint> offset;    // panel id -> its place inside the box
    };
    QVector<Group> windowGroups() const;

    // Map the current groups onto real windows: one mapped QWindow per group,
    // every member's gate reparented into it at its offset, the rest unmapped.
    // An unmapped toplevel is not a compositor snap candidate; that is why this
    // exists.
    void applyGroups();

    // Keep this plugin's windows up when melo is minimized, pinned above
    // whatever the user switched to. Re-applied whenever the caption set
    // changes, for the same reason the geometry watcher is.
    void setAlwaysUp(bool on);
    QStringList windowTitles() const;
    QString errorString() const { return error_; }

    // PluginWindowBackend — the only door MeloUiWindow has into a real window.
    QRect pluginWindowRect(const QString& id) const override;
    bool pluginWindowShown(const QString& id) const override;
    bool pluginWindowShaded(const QString& id) const override;
    void setPluginWindowShown(const QString& id, bool on) override;
    void togglePluginWindowShade(const QString& id) override;
    void startPluginWindowDrag(const QString& id) override;
    void startPluginWindowResize(const QString& id) override;
    void setPluginWindowShape(const QString& id, const QVariantList& polygons) override;

    // The size nearest `req` that the manifest's `resize: { axes, stepH, stepW,
    // minHeight, minWidth }` block permits; `decl` is the whole ui.windows[] entry,
    // since a pinned axis falls back to its declared width/height.
    // The grid is anchored at the minimum (minHeight + k*stepH), otherwise a
    // minimum that is not a multiple of the step is unreachable; with no minimum,
    // at the declared size. With no `resize` block both axes stay declared.
    // Static, so not plugin-reachable; public for tests.
    static QSize quantiseSize(const QJsonObject& decl, const QSize& req);

    // Edges a grab may take, from `axes`: bottom and right only, because the
    // docking chain is seated from the top-left and a top/left resize would move a
    // docked window with no position report. This also stops a `v`-only window being
    // dragged sideways into a width the quantiser snaps back every frame.
    static Qt::Edges resizeEdges(const QJsonObject& decl);

    // resizeEdges plus whether this window may be grabbed now; Qt::Edges() means
    // no. Split out of startPluginWindowResize because startSystemResize needs a
    // real pointer grab, so this is all a test can reach.
    Qt::Edges resizeGrabEdges(const QString& id) const;

    // Polygon list -> QRegion, separate so a test can feed it arbitrary input.
    // Public but not plugin-reachable: a static member is not a metaobject member,
    // and the facades' QObject parent (this host) does not resolve from plugin QML
    // because QML's property cache excludes QObject's own members.
    // `dropped` counts polygons the input could not express; callers report it and
    // never fail on it (see setPluginWindowShape).
    static QRegion shapeRegion(const QVariantList& polygons, int* dropped = nullptr);

private:
    // Which edge a docked window sits on: when the target resizes, a window
    // below it is re-seated on the new bottom edge, while one docked to its right
    // must not move vertically.
    enum class Dock { None, Below, Above, Right, Left };
    // Where a window docked on `edge` sits, given its target's rect and its own
    // size. The single definition of "flush": snapTarget's magnetism candidates
    // and reflowDocked's re-seating are the same four points, so a window can
    // never be re-seated somewhere magnetism would not have put it.
    static QPoint dockPoint(const QRect& target, Dock edge, const QSize& size);

    struct Win {
        QQuickWindow* win = nullptr;
        // Shell-owned item between contentItem() and the plugin's root, holding the
        // silence gate and the window size. It is a default, not a boundary:
        //   - A C++ setVisible() does not remove a QML binding, so a plugin root with
        //     `visible: <expr>` re-asserts itself; gating an ancestor fixes that
        //     without the plugin's cooperation.
        //   - A hostile plugin defeats it with `parent.visible = true`,
        //     `Window.contentItem.children[0].visible = true`, or by reparenting to
        //     `Window.contentItem`.
        //   - It gates painting, not commits: an animation in the hidden subtree still
        //     swaps ~57 frames/s and brings back the resize wobble, and arbitrary QML
        //     cannot be forced to stop scheduling updates.
        QQuickItem* gate = nullptr;
        MeloUiWindow* facade = nullptr;
        QJsonObject logicalDecl; // manifest geometry before presentation scale
        QJsonObject decl;
        QString id;              // the key this record is filed under
        QString title;
        // What the plugin asked for (show/hide). It gates PAINTING (applyState)
        // and it is also this window's extent in the docking chain (dockSize):
        // a hidden window spends no height, so the window below it sits where
        // it would sit if the hidden one were not there at all.
        bool wanted = true;
        bool shaded = false;
        int fullHeight = 0;      // height to restore when unshaded
        QPoint lastPos;          // position at the last snap pass (the delta base)
        // Where the window is. Deliberately not QWindow::position(): on Wayland
        // a client can neither position itself nor read its position back, so
        // position() answers with whatever it was last told and KWin's report
        // is the only truth. See posOf().
        QPoint pos;
        // A KWin report has arrived for this window, so position() is fiction
        // here and must never be written back over `pos`. False on X11/Windows
        // for the whole run — no report is ever generated there.
        bool kwinOwnsPos = false;
        // Melo has placed this window. Its first report may predate placement (on
        // Wayland placement waits for KWin's main-window report), and adopting it
        // splits the group on the next drag. After that, a report is KWin echoing our
        // move one device pixel off, not a user drag.
        bool placedByUs = false;
        // startPluginWindowDrag is in flight: size configures riding along with the
        // move must not snap to the resize grid or reflow the group off an edge still
        // moving. Cleared on the Finished report.
        bool userMoving = false;
        // Size at grab start, put back against the size configures KWin sends with
        // a system move. Not re-quantised: physical -> logical -> physical is lossy at
        // fractional scale (at 1.3, 301px and 303px both become 302). Invalid while no
        // move is in flight.
        QSize sizeAtGrab;
        // This panel's own size, which differs from its window's once a group shares
        // one window. Only compositor-facing code reads the QWindow size.
        QSize size;
        // How many panels this window draws. 1 is itself alone; more means it
        // is a GROUP HOST and its QWindow size is the box, not this panel's —
        // which is why the resize funnel must not read a panel size off it.
        // 0 means some other window hosts this panel.
        int hostsPanels = 1;
        bool docked = false;     // currently flush against its snapTo target
        Dock edge = Dock::None;  // ...and on which side of it
        // What the plugin last asked for, kept because the mask has TWO writers
        // (the shape and the silence rule) and one of them has to remember.
        // A null region means "rectangular" — QRegion has no empty-but-set
        // state, so this is the same value setMask() uses to clear.
        QRegion logicalShape;
        QRegion shape;
    };

    void applyState(bool applyOpacity = true);   // silence + input + atomic opacity
    // Restates to the arbiter whether the FFT should run for this host. The shell
    // decides for the plugin, which never sees SpectrumSource: the condition is
    // applyState's `active_ && wanted`, so a gated window holds no FFT and a
    // silenced host releases it. Called from applyState so every visibility change
    // restates it.
    void syncSpectrum();
    void applyMask(Win& w);                      // composes shape with the silence rule

    // The window whose resize grab is in flight, if any. See beginHold.
    void beginHold(const QString& id);
    void endHold();
    // A host window's mask is the UNION of its members' shapes, each moved to
    // its own offset. setMask writes the WHOLE mask, so composing it anywhere
    // else would have one panel's shape erase its siblings.
    void applyGroupMask(const Group& g);
    void applyMasks();
    void applySnap(const QString& movedId);  // bounded; see the .cpp
    // A user drag as KWIN reports it (WindowController::windowGeometry). On
    // Wayland this is the ONLY notice melo gets that a window moved.
    void onWindowGeometry(const QString& caption, int x, int y);
    // The single reading of "where is this window" every geometry computation
    // here must use. See Win::pos.
    static QPoint posOf(const Win& w);
    // ...and its extent in the docking chain: its size while shown, nothing
    // while hidden. Every dockPoint() argument comes from here. See the .cpp for
    // why it reads `wanted` alone and not `active_ && wanted`.
    static QSize dockSize(const Win& w);
    // Re-issue the compositor-side watcher for the current caption set.
    void watchWindows();
    // Re-issue the compositor-side move glue: each leader links directly to all
    // its descendants so KWin carries a docked stack during the drag. applySnap
    // sees only the settled report and cannot move anything mid-drag without a
    // blocking DBus round trip per frame.
    void syncWindowGlue();
    // leader -> follower -> offset, as last handed to KWin. KWin moves followers
    // without telling melo, so the settled pass reads this to avoid re-placing
    // them (a visible twitch on release).
    QHash<QString, QHash<QString, QPoint>> glueLinks_;
    // force=true skips waiting for KWin's answer and lays out from whatever
    // position is known — the bounded fallback, so placement can never hang on
    // a report that does not come.
    void placeInitial(bool force = false);
    QPoint snapTarget(const QString& id, bool* snapped, Dock* edge = nullptr) const;
    void moveWindow(Win& w, const QPoint& to, QVariantList& moves);
    // Re-seat everything docked to `id` after its own size changed (shade, show,
    // hide), which applySnap's position-delta walk does not see. On a show the
    // misplaced window was below a hidden sibling, so that call is rooted at the
    // changed window's snapTo target.
    void reflowDocked(const QString& id);
    // Queue a reflow: a grip drag sends one configure per frame, and a reflow
    // ends in a blocking DBus call into KWin (wc_->moveWindows()). See the .cpp for
    // why it also waits out a drag mid-settle.
    void reflowLater(const QString& id);
    // Restate the manifest's size limits on the QWindow so KWin never offers a
    // wrong size; min == max on an axis makes KWin refuse that axis. Re-asserted on
    // every shade toggle: a shade height is below the minimum, and
    // QWindowPrivate::setMinOrMaxSize resizes a window outside its limits.
    void applySizeLimits(Win& w);
    // Queue a facade `changed()` instead of emitting it here. See the .cpp:
    // that signal is a call INTO plugin QML, and plugin QML can make the shell
    // rebuild the provider, which destroys this host.
    void notifyLater(const QString& id);
    void teardown();

    PluginUiHost* ui_;
    QPointer<MeloUi> bridge_;
    QPointer<QWindow> transientParent_;
    QPointer<WindowController> wc_;
    // The FFT arbiter. QPointer, not a raw pointer: the instance is a stack
    // local in main() that outlives every host built here, but a null read is
    // the right answer if that ever stops being true — this host must not be
    // the thing that dereferences it.
    QPointer<SpectrumSource> spectrum_;
    // Per-instance key in the arbiter's owner set: one host is built per
    // ui-granted plugin, and under a shared key one host's setActive(false) would
    // release the FFT under another's live windows.
    const QString spectrumOwner_;
    QHash<QString, Win> wins_;
    QStringList order_;          // declaration order — deterministic iteration
    QTimer* settle_ = nullptr;   // position changes settle before snapping
    QTimer* notify_ = nullptr;   // facade changed() leaves the shell's own stack
    QTimer* resettle_ = nullptr; // size changes settle before the group re-seats
    QStringList pendingNotify_;
    QStringList pendingReflow_;
    QString movedId_;
    QString primaryId_, error_;
    // The main window's position as KWin reports it; Qt has none on Wayland.
    // Placement requests a report on demand (reportMainGeometry) rather than
    // waiting on the watcher, which fires only at install and after a user drag,
    // and places nothing if none arrives.
    QPoint mainPos_;
    bool haveMainPos_ = false;
    bool placeWanted_ = false;
    int baseSnapDistance_ = 10;
    int snapDistance_ = 10;
    double scale_ = 1.0;
    bool active_ = false;
    bool moving_ = false;        // guards the synchronous setPosition only
    // HOLD STILL: the shell is being resized. Gated in applyState beside
    // `wanted`, so it stops a plugin's content the same way hiding does — see
    // setFrozen for why this is not a flag plugins opt into.
    bool frozen_ = false;
    bool alwaysUp_ = false;
    QString holdId_;   // the window the user is resizing right now; see beginHold
    bool holdArmed_ = false;        // the pointer release is listening; see beginHold
};
