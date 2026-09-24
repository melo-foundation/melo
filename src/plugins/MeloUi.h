#pragma once
#include "MeloUiArchives.h"
#include "MeloUiQueueView.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <cstdio>
#include <QPointer>
#include <QRect>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class PlayerState;
class PlaybackCoordinator;
class SidecarService;
class QueueModel;
class SpectrumSource;
class SuggestionsModel;

// The plugin engine's only door: everything on these facades is plugin-reachable
// attack surface. Additive read/call facades remain backwards-compatible; removals or changed semantics
// require an API version bump. Facades wrap melo's real types so internals can
// be renamed without breaking plugins.
class MeloUiPlayer : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool playing READ playing NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(double position READ position NOTIFY changed)
    Q_PROPERTY(double duration READ duration NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)
    Q_PROPERTY(QString channel READ channel NOTIFY changed)
    Q_PROPERTY(bool hasTrack READ hasTrack NOTIFY changed)
    Q_PROPERTY(double volume READ volume NOTIFY changed)
    Q_PROPERTY(double balance READ balance NOTIFY changed)
    Q_PROPERTY(bool shuffle READ shuffle NOTIFY changed)
    // 0 off, 1 one, 2 all — an index, because that is what a skin's three-state
    // repeat button cycles through (Winamp shufrep.bmp).
    Q_PROPERTY(int repeat READ repeat NOTIFY changed)
public:
    MeloUiPlayer(PlayerState* state, PlaybackCoordinator* coord, QObject* parent = nullptr);

    bool playing() const;
    bool loading() const;
    double position() const;
    double duration() const;
    QString title() const;
    QString channel() const;
    bool hasTrack() const;
    double volume() const;
    double balance() const;
    bool shuffle() const;
    int repeat() const;

    // play/pause/stop/next/prev call PlaybackCoordinator *Builtin() and bypass
    // the intercept dispatcher (a hello-intercept call-through must not re-offer).
    // stopBuiltin is pause-and-rewind, which is what a skinned player's stop
    // button means.
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void prev();
    Q_INVOKABLE void seek(double seconds);
    Q_INVOKABLE void setVolume(double v);
    Q_INVOKABLE void setBalance(double v);
    Q_INVOKABLE void setShuffle(bool on);
    Q_INVOKABLE void setRepeat(int mode);

signals:
    void changed();

private:
    PlayerState* state_;
    PlaybackCoordinator* coord_;
};

// A plugin sees remote_ (the sidecar's authoritative bag) with un-acked local
// writes laid over it, so reply-1 of set("a",1); set("b",2) cannot erase b. A
// write leaves the overlay only on its own reply, so an earlier ack never
// clobbers a later write; a failure rolls the key back to the confirmed value.
class MeloUiSettings : public QObject {
    Q_OBJECT
    // A method-only API would not be reactive: `get("k")` in a QML binding never
    // re-evaluates, so a plugin's UI would freeze at its first read. Expose the
    // map as a NOTIFYing property and let plugins bind MeloUi.settings.values.k
    Q_PROPERTY(QVariantMap values READ values NOTIFY changed)
public:
    MeloUiSettings(QString pluginId, SidecarService* sidecar, QObject* parent = nullptr);

    QVariantMap values() const { return values_; }
    Q_INVOKABLE QVariant get(const QString& key) const;
    Q_INVOKABLE void set(const QString& key, const QVariant& value);

    // Reply side of the optimistic-write state machine: public for the shell,
    // not Q_INVOKABLE or slots, so plugin QML cannot forge an authoritative bag.
    // refresh() issues the fetch itself because ordering the bag against
    // in-flight writes needs the seq in effect when the fetch went out.
    void refresh();
    void onWriteReply(quint64 seq, const QString& key, const QJsonObject& reply);
    void onWriteFailed(quint64 seq, const QString& key);

signals:
    void changed();

private:
    void applyRemote(const QVariantMap& v, quint64 seq);
    void recompute();

    struct Pending { quint64 seq; QVariant value; };

    QString id_;
    SidecarService* sidecar_;
    QVariantMap values_;                  // = remote_ + pending_, what QML reads
    QVariantMap remote_;                  // last bag the sidecar confirmed
    QHash<QString, Pending> pending_;     // un-acked local writes
    // seq stamps EVERY message this object sends, reads and writes alike. One
    // ordered pipe, one sequential handler loop on the far side, so send order
    // is processing order — which is what makes "an older seq carries an older
    // bag" true. It stays true only while messages are SENT in seq order.
    quint64 nextSeq_ = 1;
    quint64 lastRemoteSeq_ = 0;           // newest bag applied; older replies are stale
    bool refreshWanted_ = false;          // asked for, and no bag has arrived yet
};

// Reads go through the mirror; writes go only through PlaybackCoordinator,
// which owns sequencing (what plays after a removal, history, prefetch,
// crossfade) and would keep steering from a stale list if QueueModel changed.
class MeloUiQueue : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject* model READ model CONSTANT)
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY changed)
    Q_PROPERTY(int count READ count NOTIFY changed)
public:
    MeloUiQueue(QueueModel* queue, PlaybackCoordinator* coord, QObject* parent = nullptr);

    QObject* model() const;
    int currentIndex() const;
    int count() const;

    Q_INVOKABLE void jumpTo(int i);
    Q_INVOKABLE void removeAt(int i);
    Q_INVOKABLE void move(int from, int to);
    Q_INVOKABLE void clear();

signals:
    void changed();

private:
    // queue_/coord_ are unreachable from plugins and stay raw; view_ is
    // plugin-reachable, so a QPointer turns any future early death into null.
    QueueModel* queue_;
    PlaybackCoordinator* coord_;
    QPointer<MeloUiQueueView> view_;
};

// Suggestions are separate from the queue: direct tracks and clicked
// suggestions leave QueueModel empty, so a plugin reading only MeloUi.queue
// shows nothing for ordinary playback. Activation goes through PlaybackCoordinator.
class MeloUiSuggestions : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject* model READ model CONSTANT)
    Q_PROPERTY(int count READ count NOTIFY changed)
public:
    MeloUiSuggestions(SuggestionsModel* suggestions, PlaybackCoordinator* coord,
                      QObject* parent = nullptr);

    QObject* model() const;
    int count() const;
    Q_INVOKABLE void play(int i);

signals:
    void changed();

private:
    SuggestionsModel* suggestions_;
    PlaybackCoordinator* coord_;
    QPointer<MeloUiSuggestionsView> view_;
};

// SpectrumSource is not exposed, because its metaobject would give plugins:
//   - request(owner, on), the FFT arbiter: a plugin could switch off the
//     analysis melo's visualizers read, or pin the FFT on forever. Showing and
//     hiding its own windows (setPluginWindowShown -> syncSpectrum) moves only
//     its host's key, only while the host is active, and teardown releases it;
//     the residue is FFT cost while the plugin's windows are on screen.
//   - updated(), which QML can emit as well as connect to, firing melo's own
//     shell handlers. This facade's `updated` has no listeners in melo.
// deleteLater() is not a risk: QML's property cache excludes QObject's own
// members (Qt 6.10.3), and destroy() refuses a C++-owned object.
class MeloUiSpectrum : public QObject {
    Q_OBJECT
public:
    MeloUiSpectrum(SpectrumSource* src, QObject* parent = nullptr);

    Q_INVOKABLE QVariantList bins() const;
    Q_INVOKABLE QVariantList wave() const;
    Q_INVOKABLE int binCount() const;
    Q_INVOKABLE int waveCount() const;

signals:
    void updated();

private:
    SpectrumSource* src_;
};

// No EQ state here: bands and preamp read through the coordinator, and all
// three writers (this, EqWindow.qml, applyEqConfig) land on the engine, with
// eqChanged firing for each. A plugin's setBand redraws EqWindow but does not
// persist; eqConfig stays the user's preset. Covered by tst_eqsync.
class MeloUiEq : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList bands READ bands NOTIFY changed)
    Q_PROPERTY(double preamp READ preamp NOTIFY changed)
public:
    MeloUiEq(PlaybackCoordinator* coord, QObject* parent = nullptr);

    QVariantList bands() const;      // 10 entries, dB, -24..+12
    double preamp() const;           // dB, -12..+12
    Q_INVOKABLE void setBand(int index, double db);
    Q_INVOKABLE void setPreamp(double db);

signals:
    void changed();

private:
    PlaybackCoordinator* coord_;
};

// The shell side of one plugin window; PluginWindowHost implements it. Not a
// QObject, so nothing here is plugin-reachable. Never hand plugin QML a
// QQuickWindow or QQuickItem: every public or protected member up from QObject
// resolves, making close(), setParent(), grabWindow() and setFlags() callable.
class PluginWindowBackend {
public:
    virtual ~PluginWindowBackend() = default;
    virtual QRect pluginWindowRect(const QString& id) const = 0;
    virtual bool pluginWindowShown(const QString& id) const = 0;
    virtual bool pluginWindowShaded(const QString& id) const = 0;
    virtual void setPluginWindowShown(const QString& id, bool on) = 0;
    virtual void togglePluginWindowShade(const QString& id) = 0;
    virtual void startPluginWindowDrag(const QString& id) = 0;
    // No size parameter, deliberately — see MeloUiWindow::startResize().
    virtual void startPluginWindowResize(const QString& id) = 0;
    virtual void setPluginWindowShape(const QString& id, const QVariantList& polygons) = 0;
};

// One entry of MeloUi.window. Geometry is READ-ONLY on purpose: the shell owns
// snapping, docking and clamping, so a plugin asks
// to move (startDrag) rather than computing where a window goes.
class MeloUiWindow : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString id READ id CONSTANT)
    Q_PROPERTY(int x READ x NOTIFY changed)
    Q_PROPERTY(int y READ y NOTIFY changed)
    Q_PROPERTY(int width READ width NOTIFY changed)
    Q_PROPERTY(int height READ height NOTIFY changed)
    Q_PROPERTY(bool visible READ visible NOTIFY changed)
    Q_PROPERTY(bool shaded READ shaded NOTIFY changed)
public:
    MeloUiWindow(QString id, PluginWindowBackend* backend, QObject* parent = nullptr);

    QString id() const { return id_; }
    int x() const;
    int y() const;
    int width() const;
    int height() const;
    // What the PLUGIN asked for, not whether pixels reach the screen: a
    // silenced host (setActive(false)) or a hidden window (!wanted) is
    // compositor-silent regardless, and a skin's "EQ" button must still light
    // up for the window it opened.
    bool visible() const;
    bool shaded() const;

    Q_INVOKABLE void show();
    Q_INVOKABLE void hide();
    Q_INVOKABLE void toggleShade();
    Q_INVOKABLE void startDrag();

    // Hands the user's resize gesture to the shell, as startDrag() does a move.
    // No resize(w, h): a binding could drive an unclamped size every frame, and
    // the manifest has no maximum to clamp against. Edges come from the
    // manifest's `axes` (v -> bottom, h -> right, vh -> bottom-right corner).
    // No-op without a `resize` block, when shaded, or outside mini mode.
    Q_INVOKABLE void startResize();

    // Window shape for non-rectangular skins (e.g. a Winamp region.txt, parsed
    // by the plugin). `polygons` is a list of polygons, each a list of points
    // ({x:,y:} or [x,y]) or a flat x,y,x,y,... list. Empty clears the shape.
    // Unusable polygons are dropped rather than failing the load. Acts only on
    // this facade's own window; do not add an id parameter.
    //
    // setMask is input-only on Wayland (Qt 6.10.3 + KWin: set_input_region, no
    // clip) and bounding-shape-only on X11 (pixels clipped, input unshaped). A
    // skin must draw transparency in its sprite alpha and also call this; on X11 a
    // wrong shape crops the skin. Applied at the surface's next commit.
    Q_INVOKABLE void setShape(const QVariantList& polygons);

    // Shell-only: public but neither Q_INVOKABLE nor a slot, so QML cannot
    // resolve it (same rule that keeps MeloUiSettings::refresh() out of reach).
    void notifyChanged() { emit changed(); }

signals:
    void changed();

private:
    QString id_;
    PluginWindowBackend* backend_;   // PluginWindowHost; outlives this facade (it is the parent)
};

// MeloUi.app. Every method only emits a request and the shell decides; QML can
// emit the signals directly, so none may carry authority. exitMiniMode() means
// dismiss (PluginWindowHost::dismissWindows hides this plugin's windows); a
// skin's close and eject buttons go dead if its signal is left unconnected.
class MeloUiApp : public QObject {
    Q_OBJECT
public:
    explicit MeloUiApp(QObject* parent = nullptr) : QObject(parent) {}

    Q_INVOKABLE void exitMiniMode()       { emit exitMiniModeRequested(); }
    Q_INVOKABLE void openPluginSettings() { emit pluginSettingsRequested(); }
    Q_INVOKABLE void setScale(double scale) { emit scaleRequested(scale); }
    // Hides melo's window the way shrinking to the compact bar does, for a skin
    // that is the player. The shell restores itself whenever this plugin's
    // windows go away, so a plugin cannot leave nothing on screen.
    Q_INVOKABLE void setShellHidden(bool hidden) { emit shellHiddenRequested(hidden); }
    // Stay up when melo is minimized, above whatever the user switched to. For
    // a skin that carries the whole transport: minimizing melo should put melo
    // away, not the player. Off unless you ask, and forgotten on teardown like
    // every other request here.
    Q_INVOKABLE void setWindowsAlwaysUp(bool on) { emit alwaysUpRequested(on); }

signals:
    void exitMiniModeRequested();
    void pluginSettingsRequested();
    void scaleRequested(double scale);
    void shellHiddenRequested(bool hidden);
    void alwaysUpRequested(bool on);
};

class MeloUi : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject* player READ player CONSTANT)
    Q_PROPERTY(QObject* settings READ settings CONSTANT)
    Q_PROPERTY(QObject* queue READ queue CONSTANT)
    Q_PROPERTY(QObject* suggestions READ suggestions CONSTANT)
    Q_PROPERTY(QObject* eq READ eq CONSTANT)
    Q_PROPERTY(QObject* spectrum READ spectrum CONSTANT)
    // Read-only archive access by SETTINGS KEY. No API under it accepts a path
    // — see MeloUiArchives.
    Q_PROPERTY(QObject* archives READ archives CONSTANT)
    // id -> MeloUiWindow. A plain QVariantMap, so what QML gets is a JS object
    // of facades and nothing else — no QQmlPropertyMap (a QObject with its own
    // surface), no window types. NOT constant: the map is populated once the
    // shell has created the windows, which is after this object exists.
    Q_PROPERTY(QVariantMap window READ window NOTIFY windowsChanged)
    Q_PROPERTY(QObject* app READ app CONSTANT)
    Q_PROPERTY(QString pluginId READ pluginId CONSTANT)
    Q_PROPERTY(QString pluginDir READ pluginDir CONSTANT)
public:
    MeloUi(QString pluginId, QString pluginDir, PlayerState* state,
           PlaybackCoordinator* coord, SidecarService* sidecar,
           QueueModel* queue, SuggestionsModel* suggestions,
           SpectrumSource* spectrum, QObject* parent = nullptr);

    // QPointers: a facade destroyed early reads back as null, which callers
    // handle. Plugin QML cannot delete them today; this guards future teardown.
    QObject* player() const { return player_.data(); }
    QObject* settings() const { return settings_.data(); }
    QObject* queue() const { return queue_.data(); }
    QObject* suggestions() const { return suggestions_.data(); }
    QObject* eq() const { return eq_.data(); }
    QObject* spectrum() const { return spectrum_.data(); }
    QObject* archives() const { return archives_.data(); }
    QVariantMap window() const { return windows_; }
    QObject* app() const { return app_.data(); }
    QString pluginId() const { return id_; }
    QString pluginDir() const { return dir_; }

    // Typed accessors for the shell only — not reachable from QML, which sees
    // the QObject* property above. Null once the facade is gone:
    // the shell must check, exactly as it would for any plugin-visible object.
    MeloUiSettings* settingsObj() const { return settings_.data(); }
    MeloUiApp* appObj() const { return app_.data(); }
    MeloUiArchives* archivesObj() const { return archives_.data(); }

    // The plugin's validated manifest `settings` array: the allowlist
    // MeloUi.archives resolves keys against. Set before plugin QML runs and on
    // every manifest reload. Not invokable: a plugin setting its own schema
    // could allow any path through MeloUi.archives.
    void setSettingsSchema(const QJsonArray& settings);

    // Called by PluginWindowHost once its windows exist, and again with an
    // empty map when it is torn down — a stale map would hand plugin QML a
    // freed facade. Not Q_INVOKABLE, not a slot: a plugin must not be able to
    // install its own `window` map.
    void setWindows(const QVariantMap& windows);

signals:
    void windowsChanged();

private:
    QString id_, dir_;
    QVariantMap windows_;
    QPointer<MeloUiPlayer> player_;
    QPointer<MeloUiSettings> settings_;
    QPointer<MeloUiQueue> queue_;
    QPointer<MeloUiSuggestions> suggestions_;
    QPointer<MeloUiEq> eq_;
    QPointer<MeloUiSpectrum> spectrum_;
    QPointer<MeloUiArchives> archives_;
    QPointer<MeloUiApp> app_;
};
