#pragma once
#include <QColor>
#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QQuickWindow>
#include <QHash>
#include <QSet>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QtGlobal>

class QQuickWindow;

// Mini-player support: main and mini are both permanently mapped (mapping
// triggers WM animations and loses positions on Wayland); "hidden" is fully
// transparent with the input region off-surface.
// GeometryReceiver: DBus landing pad for KWin-script geometry callbacks. The
// payload is one string ("x,y,w,h,inside") because callDBus marshals JS
// numbers as doubles, which do not match int slots. `inside` = cursor within
// a melo window; after a drag grab the app gets no enter until the mouse moves.
#ifndef Q_OS_WIN
class GeometryReceiver : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "com.melo.Geometry")
public slots:
    void Report(const QString& geo) {
        // KWin raises interactiveMoveResizeStarted for moves too, so the script
        // says which; only a resize needs anything held still. Bare "start"
        // stays a resize so an older payload cannot become a move.
        if (geo == QLatin1String("start")) { emit resizeStarted(); return; }
        if (geo == QLatin1String("startMove")) { emit moveStarted(); return; }
        const QStringList p = geo.split(',');
        if (p.size() >= 4)
            emit reported(int(p[0].toDouble()), int(p[1].toDouble()),
                          int(p[2].toDouble()), int(p[3].toDouble()),
                          p.size() >= 5 && p[4].toInt() == 1);
    }
    // The same landing pad for one named window (watchWindowGeometry), one
    // string for the same reason. "caption,x,y,w,h": the caption is everything
    // left of the last four fields, so a comma in it round-trips. A non-numeric
    // field drops the report; 0 would move the window to the screen corner.
    void ReportWindow(const QString& geo) {
        const QStringList p = geo.split(',');
        if (p.size() < 5) return;
        const qsizetype n = p.size();
        const QString caption = QStringList(p.mid(0, n - 4)).join(QLatin1Char(','));
        if (caption.isEmpty()) return;
        bool ok[4] = {false, false, false, false};
        const double v[4] = {p[n - 4].toDouble(&ok[0]), p[n - 3].toDouble(&ok[1]),
                             p[n - 2].toDouble(&ok[2]), p[n - 1].toDouble(&ok[3])};
        for (const bool b : ok) if (!b) return;
        emit windowReported(caption, int(v[0]), int(v[1]), int(v[2]), int(v[3]));
    }
signals:
    void reported(int x, int y, int w, int h, bool cursorInside);
    void resizeStarted();
    void moveStarted();
    void windowReported(const QString& caption, int x, int y, int w, int h);
};
#endif

class WindowController : public QObject {
    Q_OBJECT
    // "Any melo window has keyboard focus", from QGuiApplication::
    // focusWindowChanged. Per-window QWindow::active goes stale on Wayland/KWin:
    // melo/melo-mini share a taskbar entry, KWin may focus the hidden one, and
    // its active-false transition can change without emitting.
    Q_PROPERTY(bool appActive READ appActive NOTIFY appActiveChanged)
    // The window's real scale. QML's `Screen.devicePixelRatio` is the output's
    // integer buffer scale (2 on a session rendering windows at 1.1 or 1.9;
    // the fraction arrives per surface via wp-fractional-scale). A counter
    // because QWindow::devicePixelRatio has no NOTIFY: it counts
    // QEvent::DevicePixelRatioChange. Read it inside a binding to re-run it:
    //     readonly property real dpr: (WindowCtl.dprGeneration,
    //                                  WindowCtl.dprOf(Window.window))
    Q_PROPERTY(int dprGeneration READ dprGeneration NOTIFY dprGenerationChanged)
public:
    explicit WindowController(QObject* parent = nullptr);
    bool appActive() const { return appActive_; }
    int dprGeneration() const { return dprGen_; }
    // Per window: two melo windows can sit on screens at different scales. 0
    // for a null window, so a caller can hold off until attached. Arms the
    // counter's event filter on first use.
    Q_INVOKABLE qreal dprOf(QQuickWindow* win) {
        if (!dprArmed_ && qGuiApp) { qGuiApp->installEventFilter(this); dprArmed_ = true; }
        return win ? win->effectiveDevicePixelRatio() : 0.0;
    }
    ~WindowController() override;   // unloads persistent KWin scripts

    // enabled=false: input region moved off-surface -> window is click-through.
    // Writes the whole mask, so plugin windows must not use it: a skin's
    // region.txt shape is the same QWindow::setMask write, composed by
    // PluginWindowHost::applyMask, and this would erase it.
    Q_INVOKABLE void setInputEnabled(QQuickWindow* win, bool enabled);
    // KWin blur-behind (glass): no-op without MELO_NATIVE_BLUR or KF6 WindowSystem.
    // NB: blur is a SURFACE property independent of content opacity — a
    // transparent-but-mapped window still blurs, so callers must turn it
    // off on hidden counterpart windows (mini/full ghosting).
    Q_INVOKABLE void setBlurBehind(QQuickWindow* win, bool on);
    // blur only a sub-rect (mini-mode queue overlay inside the main window)
    Q_INVOKABLE void setBlurRegion(QQuickWindow* win, int x, int y, int w, int h);
    // KWin background-contrast: per-window modulation of the blurred backdrop
    // (blur strength is compositor-global). Contrast and saturation only: KWin
    // 6.5+ ignores intensity and never reads frost (see WaylandBlur.cpp).
    Q_INVOKABLE void setBackgroundContrast(QQuickWindow* win, bool on,
                                           double contrast, double saturation);
    Q_INVOKABLE bool blurAvailable() const;
    // window corner radius for the blur region (so glass follows rounded
    // corners instead of frosting the square area behind them)
    Q_INVOKABLE void setBlurRadius(int r) { blurRadius_ = r; }

    // desktop integration, same as the rest of this object: QML has no
    // clipboard type of its own
    Q_INVOKABLE void copyToClipboard(const QString& text);

    // QML console.log is a no-op on builds where Qt's debug output is
    // compiled out — which is every Qt app on some distributions, and is why
    // a QML failure can leave no trace at all. This always prints.
    Q_INVOKABLE void logLine(const QString& text);
    // recent KWin dropped the contrast effect — the sliders hide without it
    // Defined per backend: asking KWin over D-Bus whether an effect NAMED
    // "contrast" is loaded answers no on compositors that plainly support it,
    // so where we speak the protocol ourselves we ask the protocol.
    Q_INVOKABLE bool contrastAvailable() const;
    // true when KWin scripting is available (atomic pair-opacity swap works)
    Q_INVOKABLE bool kwinAvailable() const { return kwinAvailable_; }
    // clicks land only inside the given rect; everything else passes through
    Q_INVOKABLE void setInputRegion(QQuickWindow* win, int x, int y, int w, int h);
    // NB: child windows (wl_subsurface) were tested for the mini popup and
    // are WORSE than a toplevel — Qt subsurfaces are desynchronized, their
    // commits tear against the parent's interactive resize.

    // Align the INVISIBLE counterpart before an opacity flip (KWin script,
    // blocking; pure moves — sizes must already match):
    //  collapse: place "melo-mini" over the bottom barHeight px of "melo"
    //  expand:   place "melo" so its bar region lands under "melo-mini"
    Q_INVOKABLE bool alignForCollapse(int barHeight);
    // `width` is what the caller wants the window to end up; 0 keeps whatever
    // the compositor currently has. QML sets the width and then asks for this
    // in the same turn, and the compositor has not seen that set yet — reading
    // g.width there re-applies the width it is being told to replace.
    Q_INVOKABLE bool alignForExpand(int barHeight, int width = 0);
    // Set the compositor opacity of several windows ({ "title", "opacity" }
    // maps) in one KWin script run so they change in the same composite; a
    // client-side swap leaves a 1-frame gap or double. Unlisted captions are
    // untouched, and the pid guard protects other melo instances' windows.
    // false = no KWin (QML fallback).
    Q_INVOKABLE bool setWindowOpacities(const QVariantList& windows);
    // Move several windows by caption ({ "title", "x", "y" } maps) in one
    // script run, with setWindowOpacities' pid guard and own-property lookup.
    // Wayland clients cannot position themselves, so this is the only way to
    // place or snap a plugin window; batching keeps a group move to one round trip.
    Q_INVOKABLE bool moveWindows(const QVariantList& windows);
    // pin: WindowStaysOnTopHint is a no-op on Wayland — KWin's keepAbove
    // applies to both melo windows (whichever of main/mini is visible)
    Q_INVOKABLE bool setKeepAbove(bool on);

    // Plugin windows that stay up when melo is minimized: a skin carrying the
    // transport is the player. Compositor-side, because they are transient
    // children of melo's window, and changing the transient parent after the
    // surface exists makes Qt rebuild the platform window (a flash, position
    // lost); KWin can decline the minimize. `captions` is the set
    // watchWindowGeometry() watches; empty or on=false uninstalls.
    bool setPluginWindowsAlwaysUp(const QStringList& captions, bool on);
    // Mini-queue mode: while on, a persistent KWin script keeps the MAIN
    // window aligned with its bar region under "melo-mini" (the queue overlay
    // inside main then reads as a popup above the bar), following bar drags
    // live compositor-side.
    Q_INVOKABLE bool setMiniQueueGlue(bool on);

    // Compositor-side movement for docked plugin windows: links are maps
    // { leader, follower, dx, dy }; while the leader is moved interactively,
    // KWin keeps the follower at that offset in the same frame. Followers stay
    // draggable on their own. Not Q_INVOKABLE: one process-global installation
    // owned by PluginWindowHost, like watchWindowGeometry.
    bool setPluginWindowGlue(const QVariantList& links);

    // Position persistence (Wayland: clients can't read their own position —
    // KWin reports it via a DBus callback into this process). The watcher is
    // EVENT-DRIVEN: a persistent KWin script reports once per completed
    // interactive move/resize — no polling.
    Q_INVOKABLE void watchMainGeometry();
    // One-shot report on demand, through GeometryReceiver. watchMainGeometry()
    // reports only at install and after interactive moves, so anything built
    // later (a plugin window host) would not learn the main window's position
    // until the user drags melo. false = no KWin, or no bus name.
    Q_INVOKABLE bool reportMainGeometry();
    Q_INVOKABLE bool applyMainPosition(int x, int y);
    // Position AND size in one compositor step, the way a drag on the left or
    // top edge lands: a test hook, not clamped.
    Q_INVOKABLE bool applyMainGeometry(int x, int y, int w, int h);

    // The event-driven watcher for any set of windows named by caption, which
    // drag-snapping needs on Wayland: Qt gets no xdg_toplevel position event,
    // so QWindow::xChanged never fires after a user drag.
    // `captions` is the whole set: a different set replaces the script, the
    // same set is a no-op, an empty set uninstalls. Separate from
    // watchMainGeometry() because its lifetime is the plugin window host's.
    // Not Q_INVOKABLE: `WindowCtl` is a context property of melo's QML, and
    // any QML reaching this could replace or empty the one shared installation
    // and silently stop snapping. The only caller is the C++ plugin window
    // host (same reasoning as MeloUiWindow::notifyChanged).
    bool watchWindowGeometry(const QStringList& captions);
#ifndef Q_OS_WIN
    // The generated watcher body, separate so a test can read it back. The pid
    // guard, the pid-unique bus name and the own-property lookup keep one melo
    // instance out of another's identically-captioned windows, and exist only
    // in this text. Static, so it is not a metaobject member reachable from
    // the plugin side (as with PluginWindowHost::shapeRegion).
    static QString windowGeometryScript(const QStringList& captions,
                                        qint64 pid, const QString& service);
    // Generated separately so tests can assert the pid guard, asynchronous
    // windowAdded handling and one-way leader/follower movement without a live
    // KWin session. `links` has setPluginWindowGlue's validated shape.
    static QString pluginWindowGlueScript(const QVariantList& links, qint64 pid);
#endif

signals:
    void appActiveChanged();
    void dprGenerationChanged();
    void mainGeometry(int x, int y, int w, int h, bool cursorInside);
    // interactive move/resize started on a melo window (KWin watcher);
    // mainGeometry marks the end
    void interactiveStarted();
    // The user grabbed the window to MOVE it. Nothing has to hold still for
    // this — it exists so the hover fade can be held, which a drag does need.
    void interactiveMoveStarted();
    // one watched window finished a USER move/resize (watchWindowGeometry).
    // Programmatic moves (moveWindows) do not fire it, so a snap cannot echo.
    void windowGeometry(const QString& caption, int x, int y, int w, int h);

private:
    bool isWayland_ = false;
    bool kwinAvailable_ = false;
protected:
    // both platform ctors call this once qGuiApp exists
    void initFocusTracking();
    // counts QEvent::DevicePixelRatioChange for every window in the process;
    // installed on the application, not on one window, because melo's second
    // window can be the one that moves screens. See dprGeneration.
    bool eventFilter(QObject* watched, QEvent* event) override {
        if (event && event->type() == QEvent::DevicePixelRatioChange) {
            ++dprGen_;
            emit dprGenerationChanged();
        }
        return QObject::eventFilter(watched, event);
    }
    bool appActive_ = false;
    int dprGen_ = 0;
    bool dprArmed_ = false;
private:
    bool contrastAvailable_ = false;
    int blurRadius_ = 0;
#ifndef Q_OS_WIN
    // KWin identifies a loaded script by its PLUGIN NAME, not by the file path
    // it was loaded from: unloadScript() takes the name, and loadScript()
    // returns -1 when a script of that name is already loaded. Both names below
    // must therefore be kept alongside the paths and unloaded by name.
    int glueScriptId_ = -1;
    QString glueScriptPath_, glueScriptName_;
    int watchScriptId_ = -1;
    QString watchScriptPath_, watchScriptName_;
    // The per-window watcher (watchWindowGeometry). Separate from the main
    // watcher above because it is REPLACED when the watched set changes and
    // uninstalled when the plugin window host goes away, while the main one is
    // installed once and lives as long as the app.
    int alwaysUpScriptId_ = -1;
    QString alwaysUpScriptPath_, alwaysUpScriptName_, alwaysUpBody_;
    int winWatchScriptId_ = -1;
    QString winWatchScriptPath_, winWatchScriptName_;
    // The script text currently installed — the comparison that makes a
    // re-issue with an unchanged caption set free (no KWin round trip).
    QString winWatchBody_;
    void unloadWindowWatcher();
    // Plugin dock movement is distinct from the built-in mini queue glue: the
    // latter may be active before/after provider changes, while this follows
    // the current PluginWindowHost's dynamic attachment graph.
    int pluginGlueScriptId_ = -1;
    QString pluginGlueScriptPath_, pluginGlueScriptName_, pluginGlueBody_;
    void unloadPluginWindowGlue();
    GeometryReceiver* geoReceiver_ = nullptr;
    // D-Bus destination the generated KWin scripts call back on. Pid-unique and
    // registered by THIS object, so one instance's geometry cannot reach
    // another's settings (see the ctor).
    QString geoService_;
#else
    // Win32 backend state (populated in WindowController_win.cpp)
    void* mainHwnd_ = nullptr;   // HWND, kept as void* to avoid <windows.h> in the header
    void* miniHwnd_ = nullptr;
#endif
};
