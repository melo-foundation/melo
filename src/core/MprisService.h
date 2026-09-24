#pragma once
#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QObject>
#include <QStringList>
#include <QVariantMap>

class PlaybackCoordinator;
class PlayerState;
class QWindow;

// org.mpris.MediaPlayer2 over QtDBus: Plasma
// taskbar-hover controls, media keys, KDE Connect, volume-applet entry.
class MprisService : public QObject {
    Q_OBJECT
public:
    MprisService(PlaybackCoordinator* player, PlayerState* state, QObject* parent = nullptr);

signals:
    // Wired in main.cpp to Main.qml's openExternalUri(). Queued, because it
    // arrives on the D-Bus thread.
    void openUriRequested(const QString& uri);

public:
    void setWindow(QWindow* w) { window_ = w; }

    PlaybackCoordinator* player() const { return player_; }
    PlayerState* state() const { return state_; }
    QWindow* window() const { return window_; }

    QVariantMap metadata() const;
    void propertiesChanged(const QString& iface, const QVariantMap& props);

private:
    PlaybackCoordinator* player_;
    PlayerState* state_;
    QWindow* window_ = nullptr;
};

class MprisRootAdaptor : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool CanQuit READ canQuit)
    Q_PROPERTY(bool CanRaise READ canRaise)
    Q_PROPERTY(bool HasTrackList READ hasTrackList)
    Q_PROPERTY(QString Identity READ identity)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes)
    Q_PROPERTY(QStringList SupportedMimeTypes READ supportedMimeTypes)
public:
    explicit MprisRootAdaptor(MprisService* s) : QDBusAbstractAdaptor(s), s_(s) {}
    bool canQuit() const { return true; }
    bool canRaise() const { return true; }
    bool hasTrackList() const { return false; }
    QString identity() const { return QStringLiteral("melo"); }
    QString desktopEntry() const { return QStringLiteral("melo"); }
    QStringList supportedUriSchemes() const { return {}; }
    QStringList supportedMimeTypes() const { return {}; }
public slots:
    void Raise();
    void Quit();
private:
    MprisService* s_;
};

class MprisPlayerAdaptor : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(double Rate READ rate WRITE setRate)
    Q_PROPERTY(double MinimumRate READ minimumRate)
    Q_PROPERTY(double MaximumRate READ maximumRate)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(bool CanGoNext READ canGoNext)
    Q_PROPERTY(bool CanGoPrevious READ canGoPrevious)
    Q_PROPERTY(bool CanPlay READ canPlay)
    Q_PROPERTY(bool CanPause READ canPause)
    Q_PROPERTY(bool CanSeek READ canSeek)
    Q_PROPERTY(bool CanControl READ canControl)
    // Backed by PlayerState, so Plasma's widget drives the real modes.
    // LoopStatus maps None/Track/Playlist onto repeat 0/1/2.
    Q_PROPERTY(bool Shuffle READ shuffle WRITE setShuffle)
    Q_PROPERTY(QString LoopStatus READ loopStatus WRITE setLoopStatus)
public:
    explicit MprisPlayerAdaptor(MprisService* s) : QDBusAbstractAdaptor(s), s_(s) {}
    QString playbackStatus() const;
    double rate() const { return 1.0; }
    void setRate(double) {}
    double minimumRate() const { return 1.0; }
    double maximumRate() const { return 1.0; }
    QVariantMap metadata() const { return s_->metadata(); }
    double volume() const;
    void setVolume(double v);
    qlonglong position() const;
    bool canGoNext() const { return true; }
    bool canGoPrevious() const { return true; }
    bool canPlay() const { return true; }
    bool canPause() const { return true; }
    bool canSeek() const { return true; }
    bool canControl() const { return true; }
    bool shuffle() const;
    void setShuffle(bool on);
    QString loopStatus() const;
    void setLoopStatus(const QString& s);
public slots:
    void Next();
    void Previous();
    void Pause();
    void PlayPause();
    void Stop();
    void Play();
    void Seek(qlonglong offsetUs);
    void SetPosition(const QDBusObjectPath& trackId, qlonglong positionUs);
    // The desktop file declares MimeType and %U, so a second launch hands its
    // file arguments here. URI handling lives in QML with the rest of the
    // import path; this only raises a signal.
    void OpenUri(const QString& uri) { emit s_->openUriRequested(uri); }
signals:
    void Seeked(qlonglong Position);
private:
    MprisService* s_;
};
