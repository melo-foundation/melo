#include "PlaybackCoordinator.h"
#include "AudioEngine.h"
#include "SidecarService.h"
#include "RpcClient.h"
#include "PlayerState.h"
#include "QueueModel.h"
#include "SuggestionsModel.h"
#include "SettingsStore.h"
#include "LogClock.h"
#include <cstdio>

#include <QJsonArray>
#include <QRandomGenerator>
#include <algorithm>
#include <cmath>
#include <cstdio>

// The video a play is reported as. A YouTube track is its own; an imported
// file reports as the video it is linked to, or as nothing, since its local-
// id is not a video.
static QString ytIdOf(const Track& t) {
    return t.id.startsWith(QLatin1String("local-")) ? t.youtubeId : t.id;
}

PlaybackCoordinator::PlaybackCoordinator(AudioEngine* engine, SidecarService* sidecar,
                                         PlayerState* state, QueueModel* queue,
                                         SuggestionsModel* suggestions, SettingsStore* settings,
                                         QObject* parent)
    : QObject(parent), engine_(engine), sidecar_(sidecar), state_(state),
      queue_(queue), suggestions_(suggestions), settings_(settings) {

    connect(engine_, &AudioEngine::positionTick, this, &PlaybackCoordinator::onPositionTick);
    connect(engine_, &AudioEngine::trackEnded, this, &PlaybackCoordinator::onTrackEnded);
    connect(engine_, &AudioEngine::pipelineError, this, [this](const QString& m) {
        state_->setError(m);
        // A dead stream (expired/truncated googlevideo URL) must not stop the
        // music: the first failure retries with a fresh resolve, the second
        // advances like EOS, and 3 in a row stop auto-advance so a dead network
        // does not loop the queue.
        if (!state_->hasTrack()) return;
        if (++streamErrorStreak_ > 3) {
            std::fprintf(stderr, "[melo] 3 consecutive stream errors — stopping auto-advance\n");
            return;
        }
        const Track t = state_->currentTrack();
        if (errorRetryId_ != t.id) {
            errorRetryId_ = t.id;
            std::fprintf(stderr, "[melo] stream error — retrying %s with a fresh resolve\n",
                         t.id.toUtf8().constData());
            playTrack(t, 0);
        } else {
            std::fprintf(stderr, "[melo] stream error again on %s — skipping to next\n",
                         t.id.toUtf8().constData());
            onTrackEnded();
        }
    });

    // 30s watchtime cadence
    watchtimeTimer_.setInterval(30000);
    connect(&watchtimeTimer_, &QTimer::timeout, this, [this] {
        if (cpn_.isEmpty() || engine_->paused()) return;
        const double et = engine_->position();
        if (et > lastReportedTime_) {
            sidecar_->call("report/watchtime", {{"videoId", watchtimeVideoId_}, {"cpn", cpn_},
                                                {"st", lastReportedTime_}, {"et", et},
                                                {"duration", watchtimeDuration_}});
            lastReportedTime_ = et;
        }
    });

    // plugin event hooks (one player/event stream; MPRIS/SMTC share it)
    connect(state_, &PlayerState::trackChanged, this, [this] {
        if (state_->hasTrack()) {
            const Track t = state_->currentTrack();
            sidecar_->sendPlayerEvent("trackChanged", {{"track", QVariantMap{
                {"id", t.id}, {"title", t.title}, {"channel", t.channel},
                {"duration", t.duration}, {"source", t.source}}}});
        } else {
            sidecar_->sendPlayerEvent("stopped", {});
        }
    });
    // Toggling shuffle starts a fresh lap in both directions.
    // Without this, turning shuffle on late in a queue inherits whatever the
    // last shuffled session happened to leave behind and skips those tracks.
    connect(state_, &PlayerState::shuffleChanged, this,
            &PlaybackCoordinator::resetShufflePool);

    // The single writer of the shuffle pool. A row counts as played when it
    // becomes current, not when a draw or prefetch considered it, so every play
    // path (advance, next, jumpQueue, a new queue's initial index) is covered
    // here. The same edge consumes the held draw.
    connect(queue_, &QueueModel::currentIndexChanged, this, [this] {
        pendingShuffle_ = -1;
        const int i = queue_->currentIndex();
        if (i >= 0) shufflePlayed_.insert(i);
    });
    // Rows appearing or vanishing renumber what a held draw pointed at.
    connect(queue_, &QueueModel::countChanged, this, [this] { pendingShuffle_ = -1; });
    // A repeat change can turn an exhausted pool into a fresh lap (or back),
    // so a draw made under the old mode no longer answers the same question.
    connect(state_, &PlayerState::repeatChanged, this, [this] { pendingShuffle_ = -1; });

    connect(state_, &PlayerState::isPlayingChanged, this, [this] {
        sidecar_->sendPlayerEvent("stateChanged",
            {{"playing", state_->isPlaying()},
             {"position", state_->position()}});
    });
}

// ---------------------------------------------------------------- play sources

void PlaybackCoordinator::playTrackData(const QJsonObject& o) {
    queue_->clear();
    resetShufflePool();
    state_->setRadioActive(false);
    playTrack(Track::fromJson(o), -1, PlayIntent::UserSelect);
}

void PlaybackCoordinator::playQueue(const QJsonArray& tracks, int startIndex) {
    QList<Track> q;
    for (const auto& v : tracks) q.append(Track::fromJson(v.toObject()));
    if (q.isEmpty()) return;
    state_->setRadioActive(false);
    queue_->setQueue(q, qBound(0, startIndex, int(q.size()) - 1));
    resetShufflePool();
    playTrack(queue_->at(queue_->currentIndex()), -1, PlayIntent::UserSelect);
}

// ---------------------------------------------------------------- playTrack

void PlaybackCoordinator::playTrack(const Track& t, int forceCrossfade, PlayIntent intent) {
    if (!t.isValid()) return;
    std::fprintf(stderr, "[%9.1f] [timing] PRESS track=%s\n",
                 meloLogMs(), t.id.toUtf8().constData());

    // Crossfade decision. Manual plays (clicks) are gated by crossfadeOnSkip,
    // same as next/prev. Auto-advance forces.
    const double cfDur = settings_->crossfadeSeconds();
    // Nothing audible -> nothing to fade. This must also gate the forced
    // paths (next/prev with crossfadeOnSkip): crossfading out of a paused
    // track would resume it audibly for the whole fade.
    const bool audible = cfDur > 0 && state_->hasTrack()
                         && !engine_->paused() && state_->isPlaying();
    const bool autoCf = audible && settings_->uiGet("crossfadeOnSkip", false).toBool();
    const bool wantCrossfade = (forceCrossfade >= 0 ? forceCrossfade > 0 : autoCf) && audible;

    // reset per-track state
    skipStart_ = skipEnd_ = 0;
    silenceApplied_ = false;
    crossfadeTriggered_ = false;
    currentTrackId_ = t.id;
    const quint64 gen = ++playGen_;

    // prefetched fast path (the prefetch holds a resolved URL)
    if (prefetched_["videoId"].toString() == t.id) {
        const QJsonObject pf = prefetched_;
        prefetched_ = {};
        Track merged = t;
        // Fill a missing title, never replace one: the row's title is
        // locale-aware (possibly translated) and videoDetails' is always the
        // original, so the player bar would disagree with the clicked row.
        if (merged.title.isEmpty() && !pf["title"].toString().isEmpty())
            merged.title = pf["title"].toString();
        if (!pf["channel"].toString().isEmpty()) merged.channel = pf["channel"].toString();
        if (pf["duration"].toDouble() > 0) merged.duration = pf["duration"].toDouble();
        state_->setTrack(merged);
        state_->setLoading(false);
        state_->setPosition(0);
        state_->setDuration(merged.duration);
        skipStart_ = pf["skipStart"].toDouble();
        skipEnd_ = pf["skipEnd"].toDouble();

        const QString url = pf["url"].toString();
        if (wantCrossfade) engine_->crossfadeTo(url, cfDur);
        else engine_->loadTrack(url);
        // pre-seek past leading silence
        if (skipStart_ > 0) { engine_->seekTo(skipStart_, /*cutFade=*/false); silenceApplied_ = true; }
        beginAudio(intent);
        crossfadeHandling_ = false;

        flushWatchtime();
        startWatchtime(ytIdOf(t), merged.duration);
        fetchSuggestions(ytIdOf(t));
        return;
    }

    // slow path
    state_->setTrack(t);
    state_->setLoading(true);
    pendingLoadSeek_ = -1;   // a scrub belongs to the load it was made in
    // Load-window policy: progress resets to the
    // new track immediately; without a crossfade the outgoing audio stops NOW
    // (with one, it keeps playing and fades when the new deck produces audio).
    state_->setPosition(0);
    state_->setDuration(t.duration);
    if (!wantCrossfade) engine_->stop();

    const bool pluginSource = !t.source.isEmpty() && t.source != "youtube";
    auto* c = pluginSource
        ? sidecar_->call("plugin/resolveStream", {{"sourceId", t.source}, {"trackId", t.id}}, 30000)
        : sidecar_->call("yt/getStream", {{"videoId", t.id}}, 60000);
    connect(c, &RpcCall::finished, this, [this, t, gen, wantCrossfade, intent](const QJsonValue& r) {
        onStreamResolved(t, gen, r.toObject(), wantCrossfade, intent);
    });
    connect(c, &RpcCall::failed, this, [this, gen](int code, const QString& m) {
        if (playGen_ != gen) return;
        state_->setLoading(false);
        // onTrackEnded() returns immediately while crossfadeHandling_ is set,
        // so a failed resolve during a crossfade must clear it too, or
        // auto-advance stops for the rest of the session.
        crossfadeHandling_ = false;
        crossfadeTriggered_ = false;
        // WITH the code: an expired cookie wants "sign in again", a DNS
        // failure wants "retry", and the surface cannot tell them apart from
        // the message alone.
        state_->setErrorWithCode(m, code);
    });
    fetchSuggestions(ytIdOf(t));   // parallel with the stream fetch
}

void PlaybackCoordinator::onStreamResolved(const Track& t, quint64 gen,
                                           const QJsonObject& res, bool wantCrossfade,
                                           PlayIntent intent) {
    if (playGen_ != gen) return;   // stale

    if (!res["ok"].toBool()) {
        state_->setLoading(false);
        state_->setError(res["error"].toString());
        return;
    }

    Track merged = t;
    // see the prefetch path above: fill, don't replace
    if (merged.title.isEmpty() && !res["title"].toString().isEmpty())
        merged.title = res["title"].toString();
    if (!res["channel"].toString().isEmpty()) merged.channel = res["channel"].toString();
    if (res["duration"].toDouble() > 0) merged.duration = res["duration"].toDouble();
    state_->setTrack(merged);
    state_->setLoading(false);

    const QString url = res["url"].toString();
    const double cfDur = settings_->crossfadeSeconds();
    if (wantCrossfade) engine_->crossfadeTo(url, cfDur);   // the deck buffers fast; no preload step
    else engine_->loadTrack(url);
    beginAudio(intent);
    crossfadeHandling_ = false;

    flushWatchtime();
    startWatchtime(ytIdOf(t), merged.duration);

    // async silence detection (guarded by track identity on reply)
    if (settings_->silenceSkip()) {
        auto* sc = sidecar_->call("audio/detectSilence",
            {{"source", url}, {"duration", merged.duration}, {"videoId", t.id}});
        connect(sc, &RpcCall::finished, this, [this, id = t.id](const QJsonValue& r) {
            if (currentTrackId_ != id) return;
            const QJsonObject o = r.toObject();
            skipStart_ = o["skipStart"].toDouble();
            skipEnd_ = o["skipEnd"].toDouble();
        });
    }
}

void PlaybackCoordinator::refreshTrack(const QVariantMap& fresh) {
    Track t = state_->currentTrack();
    if (t.id.isEmpty() || fresh.value("id").toString() != t.id) return;
    const QString title = fresh.value("title").toString();
    const QString channel = fresh.value("channel").toString();
    const QString thumb = fresh.value("thumbnail").toString();
    if ((title.isEmpty() || title == t.title) && (channel.isEmpty() || channel == t.channel)
        && (thumb.isEmpty() || thumb == t.thumbnail)) return;
    if (!title.isEmpty()) t.title = title;
    if (!channel.isEmpty()) t.channel = channel;
    if (!thumb.isEmpty()) t.thumbnail = thumb;
    state_->setTrack(t);
}

void PlaybackCoordinator::fetchSuggestions(const QString& videoId) {
    suggestionsCursor_.clear();
    setFetching(suggestionsFetching_, false);
    state_->setTrackInfo({});
    // an unlinked import has no video to suggest from
    if (videoId.isEmpty() || videoId.startsWith("local-")) return;
    // the panel shows skeleton rows while this is out; without the flag a
    // first load reads as "no suggestions"
    setFetching(suggestionsFetching_, true);
    // the TRACK moving on is what makes this stale; a linked import's video
    // id is not its track id
    const QString forTrack = currentTrackId_;
    auto* c = sidecar_->call("yt/getNext", {{"videoId", videoId}});
    connect(c, &RpcCall::finished, this, [this, forTrack](const QJsonValue& r) {
        if (currentTrackId_ != forTrack) return;   // a later track's fetch owns the flag now
        setFetching(suggestionsFetching_, false);
        const QJsonObject o = r.toObject();
        QList<Track> sugg;
        for (const auto& v : o["suggestions"].toArray()) sugg.append(Track::fromJson(v.toObject()));
        suggestions_->set(sugg, Track::fromJson(o["autoplay"].toObject()));
        suggestionsCursor_ = o["continuation"].toString();
        state_->setTrackInfo(o["info"].toObject().toVariantMap());
    });
}

void PlaybackCoordinator::loadMoreSuggestions() {
    if (suggestionsCursor_.isEmpty() || suggestionsFetching_) return;
    setFetching(suggestionsFetching_, true);
    const QString token = suggestionsCursor_;
    const QString forTrack = currentTrackId_;
    auto* c = sidecar_->call("yt/nextContinuation", {{"token", token}});
    connect(c, &RpcCall::finished, this, [this, forTrack](const QJsonValue& r) {
        setFetching(suggestionsFetching_, false);
        if (currentTrackId_ != forTrack) return;   // the track moved on
        const QJsonObject o = r.toObject();
        QList<Track> more;
        for (const auto& v : o["suggestions"].toArray()) more.append(Track::fromJson(v.toObject()));
        suggestions_->append(more);
        suggestionsCursor_ = o["continuation"].toString();
    });
}

// ---------------------------------------------------------------- ticks & transitions

void PlaybackCoordinator::onPositionTick(double pos, double dur) {
    // Ticks during a load come from the outgoing deck — they must not drive
    // the display, prefetch, or the crossfade trigger of the OLD context.
    // pos < 0 = deck position query failed (preroll/handoff instants):
    // passing it through would flash the progress bar empty for a frame.
    if (state_->loading() || pos < 0) return;

    // real playback progress clears the stream-error bookkeeping
    if (pos > 5.0 && (streamErrorStreak_ != 0 || !errorRetryId_.isEmpty())) {
        streamErrorStreak_ = 0;
        errorRetryId_.clear();
    }

    // a scrub made during the load applies on the first real tick (seeking
    // right at load time races the deck's preroll)
    if (pendingLoadSeek_ >= 0) {
        const double s = pendingLoadSeek_;
        pendingLoadSeek_ = -1;
        silenceApplied_ = true;   // the user's scrub outranks skipStart
        engine_->seekTo(s);
        state_->setPosition(s);
        return;
    }
    // Frozen during interactive resizes: a position update mid-resize
    // re-renders the scene between compositor configures and visibly distorts
    // content, which paused playback never does. Playback logic below still
    // runs on live values.
    if (!uiFrozen_) {
        state_->setPosition(pos);
        if (dur > 0) state_->setDuration(dur);
    }

    // retroactive skipStart (silence data arrived after start)
    if (!silenceApplied_ && skipStart_ > 0) {
        if (pos >= skipStart_) silenceApplied_ = true;
        else if (pos > 0.5) { engine_->seekTo(skipStart_, /*cutFade=*/false); silenceApplied_ = true; }
    }

    const double effectiveEnd = skipEnd_ > 0 ? skipEnd_ : dur;
    if (effectiveEnd <= 0) return;
    const double cfSec = settings_->crossfadeSeconds();

    topUpMixQueue();     // cheap: return immediately unless the queue is running low
    topUpRadioQueue();

    // prefetch triggers
    const int pfPercent = settings_->prefetchPercent();
    if (pfPercent == 0 || (dur > 0 && pos / dur >= pfPercent / 100.0)) requestPrefetch();
    if (cfSec > 0 && pos >= effectiveEnd - cfSec - 15 && effectiveEnd - cfSec - 15 > 0) requestPrefetch();

    // crossfade trigger
    if (!crossfadeTriggered_ && cfSec > 0 && effectiveEnd > cfSec && effectiveEnd - pos <= cfSec) {
        crossfadeTriggered_ = true;
        if (!crossfadeHandling_) {   // re-entry guard
            crossfadeHandling_ = true;
            pushHistory();
            advance(true);
        }
        return;
    }

    // early end at skipEnd (no crossfade configured)
    if (skipEnd_ > 0 && pos >= skipEnd_ && !crossfadeTriggered_ && cfSec <= 0)
        onTrackEnded();
}

void PlaybackCoordinator::onTrackEnded() {
    if (crossfadeHandling_) return;   // crossfade already transitioning
    if (state_->loading()) return;    // outgoing deck EOSed mid-load: the pending play owns the transition
    state_->setIsPlaying(false);
    pushHistory();
    advance(false);
}

// Which queue index follows the current one. advance(), next() and
// requestPrefetch() all come through here so they agree on what plays next.
// Asking consumes nothing: the pool records played rows, and only
// advance()/next() play.
int PlaybackCoordinator::upcomingIndex(bool honorRepeatOne) {
    const int n = queue_->count();
    const int cur = queue_->currentIndex();
    if (n <= 0) return -1;

    // repeat-one short-circuits everything, including shuffle: the mode says
    // "this track, again", and there is nothing to draw from a pool for.
    // Prefetch gets cur back and its same-track guard then suppresses
    // it, which is right — the looping track is already loaded.
    if (honorRepeatOne && state_->repeat() == PlayerState::RepeatOne && cur >= 0) return cur;

    if (state_->shuffle()) return drawShuffleIndex();
    if (cur + 1 < n) return cur + 1;
    return state_->repeat() == PlayerState::RepeatAll ? 0 : -1;   // wrap, or run out
}

// The shuffle draw is made once and held (pendingShuffle_) until the row is
// played, because prefetch resolves a stream for it a track early; a fresh roll
// per call would lose the crossfade to a synchronous resolve. An exhausted pool
// under repeat-off falls through to autoplay/stop; under repeat-all it starts a
// new lap that still counts the current row as played.
void PlaybackCoordinator::resetShufflePool() {
    shufflePlayed_.clear();
    pendingShuffle_ = -1;
    const int cur = queue_->currentIndex();
    if (cur >= 0) shufflePlayed_.insert(cur);
}

int PlaybackCoordinator::drawShuffleIndex() {
    const int n = queue_->count();
    const int cur = queue_->currentIndex();
    // A held draw survives only while it still names a real row that is not
    // the one already playing; every renumbering drops it outright (see the
    // QueueModel connections in the constructor).
    if (pendingShuffle_ >= 0 && pendingShuffle_ < n && pendingShuffle_ != cur)
        return pendingShuffle_;

    QList<int> pool;
    for (int i = 0; i < n; ++i)
        if (i != cur && !shufflePlayed_.contains(i)) pool << i;

    if (pool.isEmpty()) {
        if (state_->repeat() != PlayerState::RepeatAll) return -1;   // lap over
        shufflePlayed_.clear();
        // The track that just finished is excluded from the new lap's FIRST
        // draw only — reshuffling into the same track is heard as a stall, not
        // as randomness. It stays eligible for the rest of the lap.
        for (int i = 0; i < n; ++i)
            if (i != cur || n == 1) pool << i;
    }
    if (pool.isEmpty()) return -1;
    pendingShuffle_ = pool.at(int(QRandomGenerator::global()->bounded(pool.size())));
    return pendingShuffle_;
}

// Shared next-target logic. viaCrossfade forces fade-in.
void PlaybackCoordinator::advance(bool viaCrossfade) {
    const bool cfOnSkip = viaCrossfade;   // natural EOS = default rules; crossfade path forces
    auto proceed = [this, cfOnSkip](bool /*radioAppended*/) {
        const int target = upcomingIndex(/*honorRepeatOne=*/true);
        if (target >= 0) {
            // setCurrentIndex no-ops when the target IS the current index,
            // which is exactly what repeat-one wants: same row, played again.
            queue_->setCurrentIndex(target);
            playTrack(queue_->at(target), cfOnSkip ? 1 : -1);
        } else if (state_->repeat() == PlayerState::RepeatOne && state_->hasTrack()) {
            // Repeat-one with an EMPTY queue — playing a search result seeds no
            // queue rows, so there is no index to return to. The
            // promise is "this track again", and there is still a track.
            playTrack(state_->currentTrack(), cfOnSkip ? 1 : -1);
        } else if (suggestions_->autoplayTrack().isValid()) {
            // Played, not queued: appending would grow the queue by one row
            // per suggestion, which the user can only undo by clearing it.
            // Playing a search result seeds no queue rows either. History
            // still records it (pushHistory above), so prev works.
            playTrack(suggestions_->autoplayTrack(), cfOnSkip ? 1 : -1);
        } else {
            crossfadeHandling_ = false;   // nothing to play
        }
    };
    // Except under repeat-one, radio tops the queue up on every advance so
    // it never runs dry, but repeat-one never consumes a row. Left in, an
    // overnight repeat-one would append a track per track-length, forever.
    if (state_->radioActive() && state_->repeat() != PlayerState::RepeatOne)
        appendRadioTrackThen(proceed);
    else proceed(false);
}

void PlaybackCoordinator::appendRadioTrackThen(std::function<void(bool)> cont) {
    auto* c = sidecar_->call("radio/next");
    connect(c, &RpcCall::finished, this, [this, cont](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        if (o["ok"].toBool()) queue_->append(Track::fromJson(o["track"].toObject()));
        else state_->setRadioActive(false);
        cont(o["ok"].toBool());
    });
    connect(c, &RpcCall::failed, this, [this, cont](int, const QString&) {
        state_->setRadioActive(false);
        cont(false);
    });
}

// ---------------------------------------------------------------- user commands

bool PlaybackCoordinator::offer(const QString& action) {
    return interceptOffer_ && interceptOffer_(action);
}

void PlaybackCoordinator::setInterceptOffer(std::function<bool(const QString& action)> fn) {
    interceptOffer_ = std::move(fn);
}

void PlaybackCoordinator::setInterceptOccupied(std::function<bool(const QString& action)> fn) {
    interceptOccupied_ = std::move(fn);
}

void PlaybackCoordinator::beginAudio(PlayIntent intent) {
    const bool occupyPlay = intent == PlayIntent::UserSelect
        && interceptOccupied_ && interceptOccupied_(QStringLiteral("play"));
    if (occupyPlay) {
        engine_->setPaused(true);
        state_->setIsPlaying(false);
        if (offer(QStringLiteral("play"))) return;
        playBuiltin();
        return;
    }
    state_->setIsPlaying(true);
}

void PlaybackCoordinator::next() {
    if (offer(QStringLiteral("next"))) return;
    nextBuiltin();
}

void PlaybackCoordinator::nextBuiltin() {   // crossfadeOnSkip defaults to false: a hard cut
    pushHistory();
    // Skip during a load: orphan the in-flight resolve NOW. The radio/
    // autoplay advance below is async — without this the pending track's
    // stream lands mid-gap and starts playing at 0:00 before the target.
    if (state_->loading()) { playGen_++; state_->setLoading(false); }
    const bool cfOnSkip = settings_->uiGet("crossfadeOnSkip", false).toBool();
    // honorRepeatOne=false: a manual next moves on even under repeat-one;
    // shuffle and repeat-all still apply, as with Winamp's next button. Radio
    // only when the queue is exhausted: it is topped up in batches, since one
    // track per skip would keep the queue looking empty.
    if (state_->radioActive() && queue_->currentIndex() + 1 >= queue_->count()) {
        appendRadioTrackThen([this, cfOnSkip](bool) {
            const int target = upcomingIndex(/*honorRepeatOne=*/false);
            if (target >= 0) {
                queue_->setCurrentIndex(target);
                playTrack(queue_->at(target), cfOnSkip ? 1 : 0);
            }
        });
        return;
    }
    const int target = upcomingIndex(/*honorRepeatOne=*/false);
    if (target >= 0) {
        queue_->setCurrentIndex(target);
        playTrack(queue_->at(target), cfOnSkip ? 1 : 0);
    } else if (suggestions_->autoplayTrack().isValid()) {
        // Played, not queued — see the same branch in advance().
        playTrack(suggestions_->autoplayTrack(), cfOnSkip ? 1 : 0);
    }
}

void PlaybackCoordinator::previous() {
    if (offer(QStringLiteral("prev"))) return;
    previousBuiltin();
}

void PlaybackCoordinator::previousBuiltin() {
    // while loading, "restart current" would seek the OUTGOING deck —
    // treat previous as go-to-previous and orphan the pending resolve
    if (!state_->loading() && engine_->position() > 3) { engine_->seekTo(0); return; }
    if (state_->loading()) { playGen_++; state_->setLoading(false); }
    if (queue_->currentIndex() > 0) {
        queue_->setCurrentIndex(queue_->currentIndex() - 1);
        playTrack(queue_->at(queue_->currentIndex()), 0);
    } else if (!playHistory_.isEmpty()) {   // history fallback
        const Track prev = playHistory_.takeLast();
        playTrack(prev, 0);
    }
}

void PlaybackCoordinator::togglePlay() {
    if (state_->loading()) return;
    const QString action = engine_->paused() ? QStringLiteral("play")
                                             : QStringLiteral("pause");
    if (offer(action)) return;
    playOrPauseBuiltin();
}
void PlaybackCoordinator::playOrPauseBuiltin() {
    if (state_->loading()) return;
    engine_->setPaused(!engine_->paused());
    state_->setIsPlaying(!engine_->paused());
}
void PlaybackCoordinator::playBuiltin() {
    if (state_->loading()) return;
    if (!engine_->paused()) return;
    engine_->setPaused(false);
    state_->setIsPlaying(true);
}
void PlaybackCoordinator::pauseBuiltin() {
    if (state_->loading()) return;
    if (engine_->paused()) return;
    engine_->setPaused(true);
    state_->setIsPlaying(false);
}
void PlaybackCoordinator::stopBuiltin() {
    pauseBuiltin();
    seek(0);
}
void PlaybackCoordinator::stop() {
    if (offer(QStringLiteral("stop"))) return;
    stopBuiltin();
}

void PlaybackCoordinator::seek(double seconds) {
    if (state_->loading()) {
        // remember the scrub and apply it once the track starts, or a scrub
        // during load still starts at 0:00
        pendingLoadSeek_ = std::max(0.0, seconds);
        state_->setPosition(pendingLoadSeek_);
        return;
    }
    engine_->seekTo(seconds);
    // position ticks only flow during playback — while paused the UI would
    // keep showing the pre-seek time until resume; reflect the seek now
    const double pos = std::max(0.0, seconds);
    state_->setPosition(pos);
    sidecar_->sendPlayerEvent("seeked", {{"position", pos}});   // clamped, matches state_
    emit seeked(pos);
}
void PlaybackCoordinator::setVolume(double v) { engine_->setMasterVolume(v); state_->setVolume(v); }

// NaN would survive the clamps in both the engine and PlayerState and poison
// the panorama property, so it is rejected here rather than stored.
void PlaybackCoordinator::setBalance(double v) {
    if (!std::isfinite(v)) return;
    const double b = std::clamp(v, -1.0, 1.0);
    engine_->setBalance(b);
    state_->setBalance(b);
}

void PlaybackCoordinator::setEqBand(int band, double db) {
    engine_->setEqBand(band, db);
    emit eqChanged();
}

void PlaybackCoordinator::applyEqConfig(const QVariantMap& eq) {
    const bool enabled = eq.value("enabled", false).toBool();
    const QVariantList bands = eq.value("bands").toList();
    for (int i = 0; i < 10; ++i) {
        const double db = (enabled && i < bands.size()) ? bands[i].toDouble() : 0.0;
        engine_->setEqBand(i, db);
    }
    emit eqChanged();
}

// The engine's curve, not a copy of it. The point of the getter is that a
// reader cannot drift from the audio; caching a QVariantList here would just
// reintroduce the shadow one layer down.
QVariantList PlaybackCoordinator::eqBands() const {
    QVariantList l;
    for (double db : engine_->eqBands()) l << db;
    return l;
}

double PlaybackCoordinator::preamp() const { return engine_->preamp(); }

// NaN is rejected here for the same reason as setBalance: std::clamp passes it
// straight through, and the engine's own guard should not be the only one.
void PlaybackCoordinator::setPreamp(double db) {
    if (!std::isfinite(db)) return;
    engine_->setPreamp(std::clamp(db, -12.0, 12.0));
    emit eqChanged();
}

void PlaybackCoordinator::jumpQueue(int index) {   // does NOT clear autoplay/suggestions
    if (index < 0 || index >= queue_->count()) return;
    queue_->setCurrentIndex(index);   // marks it played
    playTrack(queue_->at(index), 0, PlayIntent::UserSelect);
}

void PlaybackCoordinator::addToQueue(const QJsonArray& tracks) {
    if (queue_->count() == 0 && state_->hasTrack()) {
        queue_->append(state_->currentTrack());   // seed with current
        queue_->setCurrentIndex(0);
    }
    for (const auto& v : tracks) queue_->append(Track::fromJson(v.toObject()));
    // Queueing a track is a background act: the panel follows the add only
    // when it is already up.
    if (state_->showPanel()) state_->setPanelMode(PlayerState::Queue);
}

// Removing and reordering renumber the rows, so the pool's indices stop
// meaning what they meant. They start a fresh lap instead of renumbering the
// set; the audible cost is at most one track heard twice in a random order.
void PlaybackCoordinator::playNext(const QJsonArray& tracks) {
    if (queue_->count() == 0 && state_->hasTrack()) {
        queue_->append(state_->currentTrack());   // seed with current
        queue_->setCurrentIndex(0);
    }
    // every insert lands at current + 1, so walking the batch backwards is
    // what keeps the tracks in the order they were given
    for (int i = int(tracks.size()) - 1; i >= 0; --i)
        queue_->insertNext(Track::fromJson(tracks.at(i).toObject()));
    // the rows after the playing one are renumbered, so the pool's marks stop
    // meaning what they meant (see removeFromQueue)
    resetShufflePool();
    if (state_->showPanel()) state_->setPanelMode(PlayerState::Queue);
}

void PlaybackCoordinator::removeFromQueue(int index) {
    queue_->removeAt(index);
    resetShufflePool();
    if (queue_->count() == 0) state_->setPanelMode(PlayerState::Suggestions);
}

void PlaybackCoordinator::reorderQueue(int from, int to) {
    queue_->move(from, to);
    resetShufflePool();
}

// The one-shot ACTION that permutes the upcoming rows, unrelated to the
// shuffle MODE beyond invalidating its pool. melo's own queue
// panel calls this; it does not touch PlayerState::shuffle.
void PlaybackCoordinator::shuffleQueue() {
    queue_->shuffleUpcoming();
    resetShufflePool();
}

void PlaybackCoordinator::clearQueue() {   // does not stop playback
    queue_->clear();
    resetShufflePool();
    state_->setRadioActive(false);
    state_->setPanelMode(PlayerState::Suggestions);
}

void PlaybackCoordinator::playSuggestion(int index) {
    const Track t = suggestions_->at(index);
    if (!t.isValid()) return;
    pushHistory();
    state_->setRadioActive(false);
    mixCursor_.clear();
    mixPlaylistId_.clear();
    queue_->clear();
    resetShufflePool();   // the rows those marks referred to are gone
    playTrack(t, -1, PlayIntent::UserSelect);
}

void PlaybackCoordinator::startRadio(const QString& videoId) {
    startRadioPlaylist("RDAMVM" + videoId, -1, videoId);
}

// Move the seed to the front, wherever the mix happened to put it. If it is
// not in the mix at all, `fallback` stands in — which is how the track you
// started from gets into a queue that forgot to include it.
void PlaybackCoordinator::seedFirst(QList<Track>& q, int& start,
                                    const QString& seedId, const Track& fallback) {
    if (seedId.isEmpty()) return;
    int at = -1;
    for (int i = 0; i < q.size(); ++i)
        if (q.at(i).id == seedId) { at = i; break; }
    Track seed = at >= 0 ? q.takeAt(at)
               : (fallback.id == seedId ? fallback : Track{});
    if (!seed.isValid()) return;
    q.prepend(seed);
    start = 0;
}

// Radio seeded by a playlist/mix id (PlaylistView row clicks pass startIndex).
void PlaybackCoordinator::playMixAt(const QJsonArray& tracks, int startIndex,
                                    const QString& playlistId, const QString& cursor) {
    QList<Track> q;
    for (const auto& v : tracks) q.append(Track::fromJson(v.toObject()));
    if (q.isEmpty()) return;
    const int start = qBound(0, startIndex, int(q.size()) - 1);

    mixPlaylistId_ = playlistId;
    mixCursor_ = cursor;
    // NOT radioActive while the list still has pages: radio appends one track
    // per advance from a SEPARATE fetch, which both drip-feeds the queue and
    // mixes in tracks the list would not have served next.
    state_->setRadioActive(false);
    queue_->setQueue(q, start);
    playTrack(q.at(start));
    topUpMixQueue();
}

bool PlaybackCoordinator::queueHasMore() const {
    return !mixCursor_.isEmpty() || state_->radioActive();
}

void PlaybackCoordinator::loadMoreQueue() {
    topUpMixQueue(/*force=*/true);
    topUpRadioQueue(/*force=*/true);
}

// Radio continuation, in batches: one track per advance would keep the queue
// one song from empty, and an endless mix would look like it was running out.
void PlaybackCoordinator::topUpRadioQueue(bool force) {
    if (!state_->radioActive() || radioFetching_) return;
    if (!force && queue_->count() - queue_->currentIndex() - 1 >= kMixTopUpBelow) return;
    setFetching(radioFetching_, true);
    auto* c = sidecar_->call("radio/nextBatch", QJsonObject{{"count", 20}}, 45000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        setFetching(radioFetching_, false);
        const QJsonObject o = r.toObject();
        if (!o["ok"].toBool()) { state_->setRadioActive(false); return; }
        for (const auto& v : o["tracks"].toArray())
            queue_->append(Track::fromJson(v.toObject()));
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString&) { setFetching(radioFetching_, false); });
}

// Keep the queue ahead of playback from the list's own cursor. `force` skips
// the remaining-tracks threshold: the user scrolled to the end of the queue and
// is asking for more now, regardless of where playback is.
void PlaybackCoordinator::topUpMixQueue(bool force) {
    if (mixCursor_.isEmpty() || mixFetching_) return;
    if (!force && queue_->count() - queue_->currentIndex() - 1 >= kMixTopUpBelow) return;
    setFetching(mixFetching_, true);
    // one natural page per call; the tick tops up again if still short
    auto* c = sidecar_->call("yt/getPlaylistMore",
                             QJsonObject{{"cursor", mixCursor_}}, 45000);
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        setFetching(mixFetching_, false);
        const QJsonObject o = r.toObject();
        if (!o["ok"].toBool()) { mixCursor_.clear(); armRadioAfterMix(); return; }
        for (const auto& v : o["tracks"].toArray())
            queue_->append(Track::fromJson(v.toObject()));
        mixCursor_ = o["cursor"].toString();
        if (mixCursor_.isEmpty()) armRadioAfterMix();   // list spent -> radio takes over
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString&) {
        setFetching(mixFetching_, false);
        mixCursor_.clear();
        armRadioAfterMix();
    });
}

// The list is exhausted (mixes end around 130-190 tracks). Hand continuation to
// radio so the mix stays effectively endless.
void PlaybackCoordinator::armRadioAfterMix() {
    if (mixPlaylistId_.isEmpty() || state_->radioActive()) return;
    state_->setRadioActive(true);
    sidecar_->call("radio/start", QJsonObject{{"playlistId", mixPlaylistId_}}, 45000);
}

void PlaybackCoordinator::startRadioPlaylist(const QString& playlistId, int startIndex,
                                            const QString& seedId) {
    state_->setRadioActive(true);
    QJsonObject params{{"playlistId", playlistId}};
    if (startIndex >= 0) params["startIndex"] = startIndex;
    auto* c = sidecar_->call("radio/start", params, 45000);
    connect(c, &RpcCall::finished, this, [this, seedId](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        if (!o["ok"].toBool()) { state_->setRadioActive(false); state_->setError(o["error"].toString()); return; }
        QList<Track> q;
        for (const auto& v : o["tracks"].toArray()) q.append(Track::fromJson(v.toObject()));
        // The sidecar returns the whole mix and a start index, so earlier rows
        // stay reachable with prev. Guarded on empty: qBound asserts when its
        // max (q.size() - 1) is -1.
        int start = q.isEmpty()
            ? 0 : qBound(0, o.value("startIndex").toInt(0), int(q.size()) - 1);
        seedFirst(q, start, seedId, state_->currentTrack());
        queue_->setQueue(q, start);
        // a whole new set of rows, so the pool must not carry the
        // previous queue's marks into the radio's first lap.
        resetShufflePool();
        if (!q.isEmpty() && q.at(start).id != currentTrackId_)   // don't restart the same track
            playTrack(q.at(start), -1, PlayIntent::UserSelect);
        state_->setShowPanel(true);
        state_->setPanelMode(PlayerState::Queue);
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        state_->setRadioActive(false);
        state_->setError(m);
    });
}

// ---------------------------------------------------------------- prefetch

void PlaybackCoordinator::requestPrefetch() {
    // Next queue item, else autoplay, where "next" is what advance() will pick,
    // not currentIndex+1: under shuffle those differ, and prefetching the wrong
    // row costs the crossfade.
    Track next;
    const int target = upcomingIndex(/*honorRepeatOne=*/true);
    if (target >= 0) next = queue_->at(target);
    else next = suggestions_->autoplayTrack();
    // guards
    if (!next.isValid() || next.id == currentTrackId_ || prefetching_ ||
        prefetched_["videoId"].toString() == next.id) return;

    prefetching_ = true;
    const bool pluginSource = !next.source.isEmpty() && next.source != "youtube";
    auto* c = pluginSource
        ? sidecar_->call("plugin/resolveStream", {{"sourceId", next.source}, {"trackId", next.id}}, 30000)
        : sidecar_->call("yt/getStream", {{"videoId", next.id}}, 60000);
    connect(c, &RpcCall::finished, this, [this, next](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        // NB: prefetching_ stays set until prefetched_ is assigned. Clearing
        // it here would leave both guards false during silence detection, and
        // every position tick would re-request the same stream (~15x a track).
        if (!o["ok"].toBool()) { prefetching_ = false; return; }   // silent; playTrack re-fetches
        QJsonObject pf{{"videoId", next.id}, {"url", o["url"]}, {"title", o["title"]},
                       {"channel", o["channel"]}, {"duration", o["duration"]},
                       {"skipStart", 0.0}, {"skipEnd", 0.0}};
        if (settings_->silenceSkip()) {
            auto* sc = sidecar_->call("audio/detectSilence",
                {{"source", o["url"].toString()}, {"duration", o["duration"].toDouble()},
                 {"videoId", next.id}});
            connect(sc, &RpcCall::finished, this, [this, pf](const QJsonValue& sr) mutable {
                const QJsonObject so = sr.toObject();
                pf["skipStart"] = so["skipStart"];
                pf["skipEnd"] = so["skipEnd"];
                prefetched_ = pf;
                prefetching_ = false;
            });
            connect(sc, &RpcCall::failed, this, [this, pf](int, const QString&) {
                prefetched_ = pf;
                prefetching_ = false;
            });
        } else {
            prefetched_ = pf;
            prefetching_ = false;
        }
    });
    connect(c, &RpcCall::failed, this, [this](int, const QString&) { prefetching_ = false; });
}

// ---------------------------------------------------------------- history & watchtime

void PlaybackCoordinator::pushHistory() {   // last 5, current track
    if (!state_->hasTrack()) return;
    playHistory_.append(state_->currentTrack());
    while (playHistory_.size() > 5) playHistory_.removeFirst();
}

void PlaybackCoordinator::startWatchtime(const QString& videoId, double duration) {
    if (!settings_->sendPlayback()) return;
    if (videoId.isEmpty() || videoId.startsWith(QLatin1String("local-"))) {
        watchtimeVideoId_.clear();   // nothing to report for an unlinked import
        return;
    }
    watchtimeVideoId_ = videoId;
    watchtimeDuration_ = duration;
    lastReportedTime_ = 0;
    cpn_.clear();
    auto* c = sidecar_->call("report/playback", {{"videoId", videoId}, {"duration", duration}});
    connect(c, &RpcCall::finished, this, [this, videoId, duration](const QJsonValue& r) {
        if (watchtimeVideoId_ != videoId) return;
        cpn_ = r.toObject()["cpn"].toString();
        if (cpn_.isEmpty()) return;
        sidecar_->call("report/delayplay", {{"videoId", videoId}, {"cpn", cpn_}, {"duration", duration}});
        watchtimeTimer_.start();
    });
}

void PlaybackCoordinator::flushWatchtime() {   // final report for previous track
    if (!cpn_.isEmpty() && !watchtimeVideoId_.isEmpty()) {
        const double et = engine_->position();
        if (et > lastReportedTime_)
            sidecar_->call("report/watchtime", {{"videoId", watchtimeVideoId_}, {"cpn", cpn_},
                                                {"st", lastReportedTime_}, {"et", et},
                                                {"duration", watchtimeDuration_}});
    }
    watchtimeTimer_.stop();
    cpn_.clear();
    watchtimeVideoId_.clear();
    lastReportedTime_ = 0;
}
