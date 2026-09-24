#pragma once
#include <QObject>
#include <QVariantMap>
#include "Track.h"

// Pure-data player state that QML binds to. PlaybackCoordinator writes it;
// MPRIS and the plugin bridge also set shuffle and repeat.
class PlayerState : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariant currentTrack READ currentTrackVar NOTIFY trackChanged)
    Q_PROPERTY(QString trackTitle READ trackTitle NOTIFY trackChanged)
    Q_PROPERTY(QString trackChannel READ trackChannel NOTIFY trackChanged)
    Q_PROPERTY(QString trackThumbnail READ trackThumbnail NOTIFY trackChanged)
    Q_PROPERTY(bool hasTrack READ hasTrack NOTIFY trackChanged)
    // YouTube's own numbers for the playing track, from the same /next
    // response the suggestions come from. Empty for local files.
    Q_PROPERTY(QVariantMap trackInfo READ trackInfo NOTIFY trackInfoChanged)
    Q_PROPERTY(bool isPlaying READ isPlaying NOTIFY isPlayingChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(double balance READ balance NOTIFY balanceChanged)
    Q_PROPERTY(bool autoplay READ autoplay WRITE setAutoplay NOTIFY autoplayChanged)
    Q_PROPERTY(bool shuffle READ shuffle WRITE setShuffle NOTIFY shuffleChanged)
    Q_PROPERTY(int repeat READ repeat WRITE setRepeat NOTIFY repeatChanged)
    Q_PROPERTY(bool radioActive READ radioActive NOTIFY radioActiveChanged)
    Q_PROPERTY(int view READ view WRITE setView NOTIFY viewChanged)
    Q_PROPERTY(bool showPanel READ showPanel WRITE setShowPanel NOTIFY showPanelChanged)
    Q_PROPERTY(int panelMode READ panelMode WRITE setPanelMode NOTIFY panelModeChanged)
    Q_PROPERTY(QString error READ error WRITE setError NOTIFY errorChanged)
    // The sidecar's own bands (rpc.ts:22): -32010 auth/cookies, -32020 yt-dlp,
    // -32030 network. Kept so an expired cookie and a DNS failure can each
    // offer the action that fixes it.
    Q_PROPERTY(int errorCode READ errorCode NOTIFY errorChanged)
    // "" while nothing is wrong; "signin", "retry" or "" — what the surface
    // should OFFER, decided from the code in one place rather than by a
    // string match in QML.
    Q_PROPERTY(QString errorAction READ errorAction NOTIFY errorChanged)

public:
    enum View { Home, Library, Search, Playlist, Visualizer };
    Q_ENUM(View)
    enum PanelMode { Suggestions, Queue, NowPlaying };
    Q_ENUM(PanelMode)
    // Winamp's repeat button cycles three states and a skin drives it as an
    // index, so this is an int enum rather than a bool pair — a pair makes
    // "one AND all" representable, which is not a state the button can produce.
    enum RepeatMode { RepeatOff = 0, RepeatOne = 1, RepeatAll = 2 };
    Q_ENUM(RepeatMode)

    explicit PlayerState(QObject* parent = nullptr) : QObject(parent) {}

    // reads
    Track currentTrack() const { return track_; }
    QVariant currentTrackVar() const { return QVariant::fromValue(track_); }
    QString trackTitle() const { return track_.title; }
    QString trackChannel() const { return track_.channel; }
    QString trackThumbnail() const { return track_.thumbnail; }
    bool hasTrack() const { return track_.isValid(); }
    QVariantMap trackInfo() const { return trackInfo_; }
    bool isPlaying() const { return isPlaying_; }
    bool loading() const { return loading_; }
    double position() const { return position_; }
    double duration() const { return duration_; }
    double volume() const { return volume_; }
    double balance() const { return balance_; }   // -1 left .. 0 centre .. +1 right
    bool autoplay() const { return autoplay_; }
    bool shuffle() const { return shuffle_; }
    int repeat() const { return repeat_; }        // 0 off, 1 one, 2 all
    bool radioActive() const { return radioActive_; }
    int view() const { return view_; }
    bool showPanel() const { return showPanel_; }
    int panelMode() const { return panelMode_; }
    QString error() const { return error_; }
    int errorCode() const { return errorCode_; }
    QString errorAction() const {
        if (error_.isEmpty()) return {};
        if (errorCode_ == -32010) return QStringLiteral("signin");
        if (errorCode_ == -32020 || errorCode_ == -32030) return QStringLiteral("retry");
        return {};
    }

    // writes (coordinator-facing; simple setters emit only on change)
    void setTrack(const Track& t) { track_ = t; emit trackChanged(); }
    void setTrackInfo(const QVariantMap& i) { trackInfo_ = i; emit trackInfoChanged(); }
    void setIsPlaying(bool v) { if (v != isPlaying_) { isPlaying_ = v; emit isPlayingChanged(); } }
    void setLoading(bool v) { if (v != loading_) { loading_ = v; emit loadingChanged(); } }
    void setPosition(double v) { position_ = v; emit positionChanged(); }
    void setDuration(double v) { if (v != duration_) { duration_ = v; emit durationChanged(); } }
    void setVolume(double v) { if (v != volume_) { volume_ = v; emit volumeChanged(); } }
    void setBalance(double v) {
        // qBound does not filter non-finite input: qMin/qMax are (a<b)?a:b and
        // every NaN comparison is false, so qBound(-1, NaN, 1) silently yields
        // -1 — a wrong value stored and notified, not a rejected one.
        if (!qIsFinite(v)) return;
        const double c = qBound(-1.0, v, 1.0);
        if (!qFuzzyCompare(c, balance_)) { balance_ = c; emit balanceChanged(); }
    }
    void setAutoplay(bool v) { if (v != autoplay_) { autoplay_ = v; emit autoplayChanged(); } }
    void setShuffle(bool v) { if (v != shuffle_) { shuffle_ = v; emit shuffleChanged(); } }
    // Clamped here as well as at the bridge: this is the WRITE of a QML
    // property, so QML (melo's or a plugin's) can bypass MeloUiPlayer::setRepeat.
    // An unrecognised value would make advance() fall through and stop music.
    void setRepeat(int v) {
        const int c = qBound(int(RepeatOff), v, int(RepeatAll));
        if (c != repeat_) { repeat_ = c; emit repeatChanged(); }
    }
    void setRadioActive(bool v) { if (v != radioActive_) { radioActive_ = v; emit radioActiveChanged(); } }
    void setView(int v) { if (v != view_) { view_ = v; emit viewChanged(); } }
    void setShowPanel(bool v) { if (v != showPanel_) { showPanel_ = v; emit showPanelChanged(); } }
    void setPanelMode(int v) { if (v != panelMode_) { panelMode_ = v; emit panelModeChanged(); } }
    void setError(const QString& e) { error_ = e; errorCode_ = 0; emit errorChanged(); }
    void setErrorWithCode(const QString& e, int code) {
        error_ = e; errorCode_ = code; emit errorChanged();
    }

signals:
    void trackChanged();
    void trackInfoChanged();
    void isPlayingChanged();
    void loadingChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void balanceChanged();
    void autoplayChanged();
    void shuffleChanged();
    void repeatChanged();
    void radioActiveChanged();
    void viewChanged();
    void showPanelChanged();
    void panelModeChanged();
    void errorChanged();

private:
    Track track_;
    QVariantMap trackInfo_;
    bool isPlaying_ = false;
    bool loading_ = false;
    double position_ = 0;
    double duration_ = 0;
    double volume_ = 1.0;
    double balance_ = 0.0;
    bool autoplay_ = true;
    bool shuffle_ = false;
    int repeat_ = RepeatOff;
    bool radioActive_ = false;
    int view_ = Home;
    bool showPanel_ = false;
    int panelMode_ = Suggestions;
    QString error_;
    int errorCode_ = 0;
};
