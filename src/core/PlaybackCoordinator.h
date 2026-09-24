#pragma once
#include <QObject>
#include <QJsonObject>
#include <QTimer>
#include <QList>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>
#include <functional>
#include "Track.h"

class AudioEngine;
class SidecarService;
class PlayerState;
class QueueModel;
class SuggestionsModel;
class SettingsStore;

// The playback brain. Owns all sequencing policy: queue advance, autoplay, radio, prefetch, crossfade
// triggers, silence skip, history, watchtime reporting. Engine + sidecar are dumb.
class PlaybackCoordinator : public QObject {
    Q_OBJECT
public:
    PlaybackCoordinator(AudioEngine* engine, SidecarService* sidecar, PlayerState* state,
                        QueueModel* queue, SuggestionsModel* suggestions, SettingsStore* settings,
                        QObject* parent = nullptr);

    // --- QML command surface ---
    Q_INVOKABLE void playTrackData(const QJsonObject& track);   // single track: queue reset
    // new title, artist or art for the track that is playing (a metadata
    // edit): shown at once, playback untouched; ignored for any other id
    Q_INVOKABLE void refreshTrack(const QVariantMap& fresh);
    Q_INVOKABLE void playQueue(const QJsonArray& tracks, int startIndex);
    Q_INVOKABLE void next();                                    // honours crossfadeOnSkip
    Q_INVOKABLE void previous();                                // falls back to history
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void stop();                                    // offer("stop") then stopBuiltin
    void setInterceptOffer(std::function<bool(const QString& action)> fn);
    void setInterceptOccupied(std::function<bool(const QString& action)> fn);
    void playBuiltin();
    void pauseBuiltin();
    void stopBuiltin();                                         // pauseBuiltin + seek(0)
    void nextBuiltin();
    void previousBuiltin();
    Q_INVOKABLE void seek(double seconds);
    Q_INVOKABLE void setVolume(double v);
    Q_INVOKABLE void setBalance(double v);                      // -1 left .. 0 centre .. +1 right
    // 10-band EQ: live band updates from the EQ window; disabled = flat
    Q_INVOKABLE void setEqBand(int band, double db);
    Q_INVOKABLE void applyEqConfig(const QVariantMap& eq);
    // Read back from the engine, in dB — not a second copy. Every writer above
    // lands in the engine, so a reader (the EQ window, a plugin) consults this
    // instead of remembering what it last wrote.
    Q_INVOKABLE QVariantList eqBands() const;
    Q_INVOKABLE double preamp() const;                          // dB
    Q_INVOKABLE void setPreamp(double db);                      // -12..+12 dB
    // uiFrozen: during an interactive window resize, tick-driven UI
    // (position/duration) freezes so the scene is static; playback continues.
    // Q_INVOKABLE so QML engages it at press on melo's own resize MouseAreas;
    // KWin's start report is a DBus round-trip late and lets one tick through.
    // Anything self-animating binds to it too (ScrollText).
    // queueLoading: a page is in flight; the queue panel shows a spinner under
    // the last row.
    Q_PROPERTY(bool queueLoading READ queueLoading NOTIFY loadingMoreChanged)
    Q_PROPERTY(bool suggestionsLoading READ suggestionsLoading NOTIFY loadingMoreChanged)
    Q_PROPERTY(bool uiFrozen READ uiFrozen NOTIFY uiFrozenChanged)
    bool uiFrozen() const { return uiFrozen_; }
    Q_INVOKABLE void setUiFrozen(bool frozen) {
        if (uiFrozen_ == frozen) return;
        uiFrozen_ = frozen;
        emit uiFrozenChanged();
    }
    Q_INVOKABLE void jumpQueue(int index);
    Q_INVOKABLE void addToQueue(const QJsonArray& tracks);
    Q_INVOKABLE void playNext(const QJsonArray& tracks);        // after the playing row
    Q_INVOKABLE void removeFromQueue(int index);
    Q_INVOKABLE void reorderQueue(int from, int to);
    Q_INVOKABLE void shuffleQueue();
    Q_INVOKABLE void clearQueue();
    // Scrolling the queue panel to the end pulls the next page immediately,
    // rather than waiting for playback to drop below the top-up threshold.
    Q_INVOKABLE void loadMoreQueue();
    Q_INVOKABLE bool queueHasMore() const;   // defined in .cpp: PlayerState is incomplete here
    // The related list is paged too: scrolling the suggestions tab to the end
    // pulls the next page from the token the last one ended on.
    Q_INVOKABLE void loadMoreSuggestions();
    Q_INVOKABLE bool suggestionsHaveMore() const { return !suggestionsCursor_.isEmpty(); }
    bool queueLoading() const { return mixFetching_ || radioFetching_; }
    bool suggestionsLoading() const { return suggestionsFetching_; }
    Q_INVOKABLE void playSuggestion(int index);                 // clears radio
    Q_INVOKABLE void startRadio(const QString& videoId);
    Q_INVOKABLE void startRadioPlaylist(const QString& playlistId, int startIndex = -1,
                                        const QString& seedId = {});

    // Song radio opens with the song it was started from. YouTube's mix
    // usually leads with the seed but not always, and otherwise the queue
    // would open on another track. Pure list surgery, so it is testable on
    // its own.
    static void seedFirst(QList<Track>& q, int& start,
                          const QString& seedId, const Track& fallback);
    // Mix played from a list view: the queue comes from the rows on screen
    // (which may be paginated well past the first page) while radio autoplay
    // stays armed. startRadioPlaylist fetches its own short list, which would
    // not reach row 50 of a paged mix.
    Q_INVOKABLE void playMixAt(const QJsonArray& tracks, int startIndex,
                               const QString& playlistId, const QString& cursor);

    // Which queue index plays after the current one, or -1 if nothing follows.
    // advance(), next() and requestPrefetch() all ask it, so prefetch resolves
    // the track the advance will pick. honorRepeatOne: end-of-track honours
    // repeat-one, a manual next does not. Not Q_INVOKABLE, so the plugin bridge
    // cannot draw from the shuffle pool.
    int upcomingIndex(bool honorRepeatOne);

signals:
    void loadingMoreChanged();
    void uiFrozenChanged();
    // Any change to the EQ curve or the preamp, whoever made it. Without this a
    // reader has to poll: a QML binding on eqBands() would latch the value it
    // first saw and never notice melo's EQ window or a plugin moving a slider.
    void eqChanged();
    // MPRIS Seeked. The spec requires it for a position change the client did
    // not ask for, which melo's own scrub is from a remote's point of view;
    // without it a controller shows the pre-scrub position until the next
    // track. Seconds; MprisService converts.
    void seeked(double seconds);

private:
    enum class PlayIntent { UserSelect, Advance };
    bool offer(const QString& action);
    void beginAudio(PlayIntent intent);                         // after loadTrack/crossfadeTo
    void playOrPauseBuiltin();
    void playTrack(const Track& t, int forceCrossfade = -1,
                   PlayIntent intent = PlayIntent::Advance);    // -1 auto, 0 no, 1 yes
    void onStreamResolved(const Track& t, quint64 gen, const QJsonObject& res, bool wantCrossfade,
                          PlayIntent intent);
    void fetchSuggestions(const QString& videoId);
    void onPositionTick(double pos, double dur);                // crossfade/skipEnd/prefetch triggers
    int streamErrorStreak_ = 0;     // consecutive pipeline errors (cap 3)
    QString errorRetryId_;          // track already given its one fresh-resolve retry
    void onTrackEnded();
    void advance(bool viaCrossfade);                            // shared next-target logic

    int drawShuffleIndex();
    // Start a fresh lap. Call it AFTER the mutation that renumbered the rows,
    // never before: it rebuilds from what is true now, which includes marking
    // the row that is playing.
    void resetShufflePool();
    void requestPrefetch();
    void pushHistory();                                         // last 5
    void appendRadioTrackThen(std::function<void(bool)> cont);
    void startWatchtime(const QString& videoId, double duration);
    void flushWatchtime();

    AudioEngine* engine_;
    SidecarService* sidecar_;
    PlayerState* state_;
    QueueModel* queue_;
    SuggestionsModel* suggestions_;
    SettingsStore* settings_;
    std::function<bool(const QString& action)> interceptOffer_;
    std::function<bool(const QString& action)> interceptOccupied_;

    // guards
    QString currentTrackId_;
    quint64 playGen_ = 0;
    bool crossfadeHandling_ = false;
    bool crossfadeTriggered_ = false;

    // prefetch
    QJsonObject prefetched_;      // {videoId, url, title, channel, duration, thumbnail, skipStart, skipEnd}
    bool prefetching_ = false;

    // Paged mix continuation. The queue is topped up from the SAME list source
    // the view paged through, well before playback reaches the end — otherwise
    // an "infinite" mix visibly drains and only extends one track at a time
    // once already exhausted. Radio is armed only after the list runs dry.
    void setFetching(bool& flag, bool v) {
        if (flag == v) return;
        flag = v;
        emit loadingMoreChanged();
    }

    QString suggestionsCursor_;   // yt/nextContinuation token, "" when exhausted
    bool suggestionsFetching_ = false;

    QString mixPlaylistId_;
    QString mixCursor_;
    bool mixFetching_ = false;
    static constexpr int kMixTopUpBelow = 10;   // keep at least this many ahead
    void topUpMixQueue(bool force = false);
    void topUpRadioQueue(bool force = false);
    void armRadioAfterMix();
    bool radioFetching_ = false;

    // silence
    double skipStart_ = 0, skipEnd_ = 0;
    bool silenceApplied_ = false;

    // scrub made while the track was still loading; applied on first tick
    double pendingLoadSeek_ = -1;
    bool uiFrozen_ = false;   // interactive resize in progress


    // history
    QList<Track> playHistory_;

    // Shuffle's not-yet-played pool, as the complement of these queue indices
    // (indices, since a queue can hold one track twice). Every structural queue
    // edit clears it (resetShufflePool() call sites). Rows are marked only when
    // they become current, so upcomingIndex() never consumes a slot; under
    // repeat=all drawShuffleIndex() refills an exhausted pool, so a prefetch
    // can start the new lap.
    QSet<int> shufflePlayed_;

    // The shuffle draw, held until the row is played so prefetch and advance
    // agree. Dropped when the queue moves or is renumbered under it; consumed
    // by the currentIndexChanged the play emits.
    int pendingShuffle_ = -1;

    // watchtime
    QTimer watchtimeTimer_;
    QString cpn_, watchtimeVideoId_;
    double lastReportedTime_ = 0, watchtimeDuration_ = 0;
};
