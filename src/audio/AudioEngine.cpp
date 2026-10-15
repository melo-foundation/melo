#include "AudioEngine.h"
#include "SourceDeck.h"
#include "PcmQueue.h"
#include "SpectrumSource.h"
#include "VideoCodecs.h"
#include "VideoDeck.h"

#include <gst/audio/streamvolume.h>
#include <gst/base/gstaggregator.h>
#include <gst/base/gstbasesink.h>
#include "../core/LogClock.h"

#include <QUrl>
#include <algorithm>
#include <cmath>
#include <cstdio>

AudioEngine::AudioEngine(PcmQueue& vizQueue, QObject* parent)
    : QObject(parent), vizQueue_(vizQueue) {
    buildPipeline();
    videoCodecs_ = videoCodecPreference([](const char* f) {
        GstElementFactory* e = gst_element_factory_find(f);
        if (e) gst_object_unref(e);
        return e != nullptr;
    });

    posTimer_.setInterval(250);
    connect(&posTimer_, &QTimer::timeout, this, [this] {
        // The INCOMING deck owns the display as soon as a crossfade begins:
        // progress tracks the new song, not the fading one.
        watchStuckSeeks();
        SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
        if (!d || paused_) { stallTicks_ = 0; return; }
        const double pos = position();
        watchStall(pos);
        emit positionTick(pos, duration());
    });
    posTimer_.start();

    fadeTimer_.setInterval(50);
    connect(&fadeTimer_, &QTimer::timeout, this, &AudioEngine::onFadeTick);
}

AudioEngine::~AudioEngine() {
    if (pipeline_) {
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        videoCurrent_.reset();
        videoIncoming_.reset();
        videoPending_.reset();
        current_.reset();
        incoming_.reset();
        retiring_.clear();
        for (GstElement* e : {audioQueue_, audibleSink_, appsink_})
            if (e) gst_object_unref(e);
        gst_object_unref(pipeline_);
    }
}

void AudioEngine::buildPipeline() {
    GError* err = nullptr;
    // Audio-branch queue capped at 40ms: with default limits it buffers a full
    // SECOND of decoded audio after the control elements, so master volume, EQ
    // and crossfade envelopes would be heard ~1s late (and the visualizer tap
    // would run ~1s ahead of the speakers). 40ms is plenty to decouple the tee.
    const bool fakeSink = qEnvironmentVariableIsSet("MELO_FAKE_SINK");   // headless tests
    // Master volume is applied at the sink (PulseAudio stream volume), which
    // affects what is playing now with no buffer latency; the viz branch has
    // its own volume element so the visualizer still scales. A small sink
    // buffer keeps the EQ responsive. Balance sits after the EQ, upstream of
    // the tee and under master volume. audiopanorama (gst-plugins-good) is
    // optional: without it the stage is omitted and setBalance() no-ops.
    GstElementFactory* panFactory = gst_element_factory_find("audiopanorama");
    // method=simple (the enum nick, never the raw 1): Winamp's balance knob just
    // attenuates the opposite channel. The default, psychoacoustic, keeps
    // perceived loudness by cross-mixing — a different control wearing the same
    // name, and not what a Winamp balance slider at ±1 is expected to do.
    const QString panStage = panFactory ? QStringLiteral("audiopanorama name=pan method=simple ! ")
                                        : QString();
    if (panFactory) gst_object_unref(panFactory);
    else std::fprintf(stderr, "[%9.1f] [audio] audiopanorama unavailable — balance disabled\n", meloLogMs());
    const auto build = [&err, &panStage](const QString& sink) {
        g_clear_error(&err);
        return gst_parse_launch(QStringLiteral(
            "audiomixer name=mix ! volume name=preamp ! equalizer-10bands name=eq ! %2tee name=t "
            "t. ! queue name=aq max-size-time=40000000 max-size-buffers=0 max-size-bytes=0 "
            "   ! audioconvert ! %1 "
            "t. ! queue leaky=downstream max-size-time=200000000 "
            "   ! volume name=vizvol ! appsink name=viz")
            .arg(sink, panStage).toUtf8().constData(), &err);
    };
    // sync=false: the device paces consumption. The mixer's output position
    // is the only timeline; it freezes across network stalls and every deck
    // pins to it, so a stall costs only the stall (no seek resuming past its
    // target, no silence between a frozen mixer and clock-pinned data).
    // Can this sink open the device? gst_parse_launch succeeds whenever the
    // plugin is installed, and pulsesink reaches the server only at READY; on
    // an ALSA-only box every track would bus-error and auto-advance would stop
    // after three. So pulsesink is taken to READY once, here, while the
    // autoaudiosink fallback can still be chosen.
    const auto sinkOpens = [](const char* factory) {
        GstElement* e = gst_element_factory_make(factory, nullptr);
        if (!e) return false;
        const bool ok = gst_element_set_state(e, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE;
        gst_element_set_state(e, GST_STATE_NULL);
        gst_object_unref(e);
        return ok;
    };
    const bool pulseUsable = fakeSink || sinkOpens("pulsesink");
    if (!fakeSink && !pulseUsable)
        std::fprintf(stderr, "[%9.1f] [audio] pulsesink will not open a device — falling back to autoaudiosink\n", meloLogMs());

    pipeline_ = (fakeSink || pulseUsable)
        ? build(fakeSink ? "fakesink name=fsink sync=true"
                         : "pulsesink name=asink sync=false buffer-time=80000 latency-time=20000")
        : nullptr;
    // Fallback keeps a volume element in the audio branch (buffered but correct).
    if (!pipeline_ && !fakeSink) pipeline_ = build("volume name=fbvol ! autoaudiosink name=autosink");
    if (!pipeline_) {
        std::fprintf(stderr, "[%9.1f] [audio] pipeline build failed: %s\n", meloLogMs(), err ? err->message : "?");
        return;
    }
    mixer_    = gst_bin_get_by_name(GST_BIN(pipeline_), "mix");
    preampEl_ = gst_bin_get_by_name(GST_BIN(pipeline_), "preamp");
    eq_       = gst_bin_get_by_name(GST_BIN(pipeline_), "eq");
    pan_      = gst_bin_get_by_name(GST_BIN(pipeline_), "pan");
    vizVol_   = gst_bin_get_by_name(GST_BIN(pipeline_), "vizvol");
    // Re-apply the stored state so a rebuild keeps the user's settings.
    if (pan_) setBalance(balance_);
    if (preampEl_) setPreamp(preampDb_);
    for (int i = 0; i < 10; ++i) setEqBand(i, eqBands_[i]);
    // Audible volume by NAME — never by interface: the viz branch's plain
    // volume element ALSO implements GstStreamVolume and an interface lookup
    // can return it (volume then never reaches the sink; full blast).
    sinkVol_ = gst_bin_get_by_name(GST_BIN(pipeline_), "asink");
    if (!sinkVol_) sinkVol_ = gst_bin_get_by_name(GST_BIN(pipeline_), "fbvol");
    std::fprintf(stderr, "[%9.1f] [audio] volume applies at: %s\n", meloLogMs(),
                 sinkVol_ ? GST_OBJECT_NAME(sinkVol_) : "NONE (fakesink test build)");
    appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "viz");
    audioQueue_ = gst_bin_get_by_name(GST_BIN(pipeline_), "aq");
    audibleSink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "asink");
    if (!audibleSink_) audibleSink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "fsink");
    if (!audibleSink_) audibleSink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "autosink");

    GstCaps* caps = gst_caps_from_string(
        "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved");
    gst_app_sink_set_caps(GST_APP_SINK(appsink_), caps);
    gst_caps_unref(caps);
    // sync=FALSE: deliver as decoded (tee realtime-paced by audio branch).
    // async=FALSE: a tap must NOT gate preroll — async deadlocks pause.
    g_object_set(appsink_, "sync", FALSE, "async", FALSE, "max-buffers", 10, "drop", TRUE, nullptr);

    GstAppSinkCallbacks cbs = {};
    cbs.new_preroll = [](GstAppSink* s, gpointer) -> GstFlowReturn {
        GstSample* smp = gst_app_sink_pull_preroll(s);
        if (smp) gst_sample_unref(smp);
        return GST_FLOW_OK;
    };
    cbs.new_sample = &AudioEngine::onNewSample;
    gst_app_sink_set_callbacks(GST_APP_SINK(appsink_), &cbs, this, nullptr);

    GstBus* bus = gst_element_get_bus(pipeline_);
    gst_bus_add_watch(bus, [](GstBus*, GstMessage* msg, gpointer user) -> gboolean {
        static_cast<AudioEngine*>(user)->onBusMessage(msg);
        return TRUE;
    }, this);
    gst_object_unref(bus);
}

// Main thread (the bus watch runs on the default GLib context).
void AudioEngine::onBusMessage(GstMessage* msg) {
    const char* from = GST_OBJECT_NAME(msg->src);
    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError* e = nullptr; gchar* dbg = nullptr;
        gst_message_parse_error(msg, &e, &dbg);
        std::fprintf(stderr, "[%9.1f] [bus] ERROR from %s: %s | %s\n", meloLogMs(),
                     from, e->message, dbg ? dbg : "");
        handleBusError(msg->src, QString::fromUtf8(e->message));
        g_error_free(e); g_free(dbg);
        break;
    }
    // logged only: what the sound server and the sink say besides errors
    case GST_MESSAGE_WARNING: {
        GError* e = nullptr; gchar* dbg = nullptr;
        gst_message_parse_warning(msg, &e, &dbg);
        std::fprintf(stderr, "[%9.1f] [bus] warning from %s: %s | %s\n", meloLogMs(),
                     from, e->message, dbg ? dbg : "");
        g_error_free(e); g_free(dbg);
        break;
    }
    case GST_MESSAGE_REQUEST_STATE: {
        GstState s = GST_STATE_VOID_PENDING;
        gst_message_parse_request_state(msg, &s);
        std::fprintf(stderr, "[%9.1f] [bus] %s asks for %s\n", meloLogMs(),
                     from, gst_element_state_get_name(s));
        break;
    }
    case GST_MESSAGE_CLOCK_LOST:
        std::fprintf(stderr, "[%9.1f] [bus] clock lost from %s\n", meloLogMs(), from);
        break;
    // the pipeline's and the audible sink's only; every element posts one
    case GST_MESSAGE_STATE_CHANGED: {
        if (GST_ELEMENT_CAST(msg->src) != pipeline_ && GST_ELEMENT_CAST(msg->src) != audibleSink_)
            break;
        GstState was = GST_STATE_VOID_PENDING, now = GST_STATE_VOID_PENDING,
                 pending = GST_STATE_VOID_PENDING;
        gst_message_parse_state_changed(msg, &was, &now, &pending);
        std::fprintf(stderr, "[%9.1f] [bus] %s %s -> %s%s%s\n", meloLogMs(), from,
                     gst_element_state_get_name(was), gst_element_state_get_name(now),
                     pending != GST_STATE_VOID_PENDING ? ", pending " : "",
                     pending != GST_STATE_VOID_PENDING ? gst_element_state_get_name(pending) : "");
        break;
    }
    default:
        break;
    }
}

// Only an error from the current deck or a shared element is the playing
// track's. One from the incoming deck drops that deck and still reports, since
// the coordinator already shows the incoming track; one from a retiring or
// torn-down deck is logged and dropped.
void AudioEngine::handleBusError(GstObject* src, const QString& message) {
    const auto inDeck = [src](const SourceDeck* d) {
        return d && d->bin() && (GST_OBJECT(d->bin()) == src
                                 || gst_object_has_as_ancestor(src, GST_OBJECT(d->bin())));
    };
    if (!messageIsFromCurrentDeck(src)) {
        if (inDeck(incoming_.get())) {
            std::fprintf(stderr, "[%9.1f] [bus] error is the incoming deck's (%s): dropping it\n",
                         meloLogMs(), GST_OBJECT_NAME(incoming_->bin()));
            dropIncoming();
            QMetaObject::invokeMethod(this, [this, message] { emit pipelineError(message); },
                                      Qt::QueuedConnection);
            return;
        }
        for (auto it = retiring_.begin(); it != retiring_.end(); ++it) {
            if (!inDeck(it->get())) continue;
            std::fprintf(stderr, "[%9.1f] [bus] error is a retiring deck's (%s): dropping it\n",
                         meloLogMs(), GST_OBJECT_NAME((*it)->bin()));
            retiring_.erase(it);
            return;
        }
        std::fprintf(stderr, "[%9.1f] [bus] error from a deck already gone: ignored\n", meloLogMs());
        return;
    }
    QMetaObject::invokeMethod(this, [this, message] {
        pipelineErrored_ = true;   // next loadTrack does a full NULL reset
        emit pipelineError(message);
    }, Qt::QueuedConnection);
}

// The outgoing deck carries on at full volume, as if the fade never began.
void AudioEngine::dropIncoming() {
    if (incoming_.get() == replacing_) replacing_ = nullptr;
    fadeTimer_.stop();
    fadeFrozen_ = false;
    fadePos_ = 0;
    pendingIncomingSeek_ = -1;
    incoming_.reset();
    incomingTrack_.clear();
    if (current_) current_->setVolume(1.0);
    if (videoIncoming_) { videoIncoming_.reset(); emit videoChanged(); }
}

// True when the element that posted a message sits inside the deck that is
// currently playing (or is the pipeline itself, which nothing else owns).
// Anything from a retiring or incoming deck is somebody else's problem.
bool AudioEngine::messageIsFromCurrentDeck(GstObject* src) const {
    if (!src) return true;
    if (GST_ELEMENT_CAST(src) == pipeline_) return true;
    // a message queued before its deck left the pipeline
    if (!gst_object_has_as_ancestor(src, GST_OBJECT(pipeline_))) return false;
    const auto inDeck = [src](const SourceDeck* d) {
        return d && d->bin() && (GST_OBJECT(d->bin()) == src
                                 || gst_object_has_as_ancestor(src, GST_OBJECT(d->bin())));
    };
    if (inDeck(current_.get())) return true;
    // Not in any deck we know about — a shared element (the mixer, the sink).
    // Those are the pipeline's own and do concern the current track.
    if (inDeck(incoming_.get())) return false;
    for (const auto& r : retiring_) if (inDeck(r.get())) return false;
    return true;
}

std::unique_ptr<SourceDeck> AudioEngine::makeDeck(const QString& pathOrUri, bool deferLink) {
    QString uri = pathOrUri;
    if (!uri.contains("://")) uri = QUrl::fromLocalFile(pathOrUri).toString();
    auto deck = std::make_unique<SourceDeck>(pipeline_, mixer_, uri.toStdString(), deferLink);

    // An immediately-linked deck joining a running pipeline needs its
    // timeline shifted to the mixer's position, else the mixer drops its
    // from-zero buffers as late. (Deferred-link decks pin at link time.)
    if (!deferLink) {
        GstState st = GST_STATE_NULL;
        gst_element_get_state(pipeline_, &st, nullptr, 0);
        if (st == GST_STATE_PLAYING || st == GST_STATE_PAUSED)
            deck->setStartOffset(deck->mixerTimelineNow());
    }

    // EOS fires on a GStreamer thread; marshal to the Qt main thread. Only the
    // CURRENT deck's EOS means "track ended" (retiring decks EOS silently).
    SourceDeck* raw = deck.get();
    deck->onReseekNeeded([this, raw] {
        QMetaObject::invokeMethod(this, [this, raw] {
            // The callback may outlive a superseded deck while queued.
            if (current_.get() == raw || incoming_.get() == raw)
                raw->continuePendingSeek();
        }, Qt::QueuedConnection);
    });
    deck->onEos([this, raw] {
        QMetaObject::invokeMethod(this, [this, raw] {
            // During a fade the OUTGOING deck is still current_ — its natural
            // EOS must NOT read as "track ended" (it would hard-advance the
            // queue and kill the fade). The INCOMING deck ending does count
            // (short track + long fade).
            if (incoming_) {
                if (incoming_.get() == raw) emit trackEnded();
                return;
            }
            if (current_.get() == raw) emit trackEnded();
        }, Qt::QueuedConnection);
    });
    return deck;
}

void AudioEngine::loadTrack(const QString& pathOrUri, const QString& trackId) {
    fadeTimer_.stop();
    forgetReplacement();
    incoming_.reset();
    retiring_.clear();      // hard cut: tear down everything old
    current_.reset();
    currentTrack_ = trackId;
    incomingTrack_.clear();
    videoIncoming_.reset();
    clearHold();
    if (videoPending_ && !videoPendingTrack_.isEmpty() && !trackId.isEmpty() && videoPendingTrack_ != trackId) {
        std::fprintf(stderr, "[%9.1f] [video] prerolled deck for %s dropped, loading %s\n", meloLogMs(),
                     qPrintable(videoPendingTrack_), qPrintable(trackId));
        videoPending_.reset();
    }
    videoCurrent_ = std::move(videoPending_);
    videoPendingTrack_.clear();
    if (videoCurrent_) videoCurrent_->start();
    emit videoChanged();
    // A pipeline that posted ERROR is wedged — every later play would fail
    // (even local files). Full NULL reset clears it; decks are rebuilt anyway.
    if (pipelineErrored_) {
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        pipelineErrored_ = false;
    }
    // ~120ms+ of the old track sits between mixer and speaker (post-mixer
    // queue + PA buffer); flushing it would reset the mixer timeline, and from
    // PAUSE it plays before the new track. Muted until the new track's first
    // buffer (sink mute is independent of the user's volume).
    setSinkMuted(true);
    current_ = makeDeck(pathOrUri);
    current_->onFirstBuffer([this] {
        QMetaObject::invokeMethod(this, [this] { setSinkMuted(false); },
                                  Qt::QueuedConnection);
    });
    gst_element_set_state(pipeline_, GST_STATE_PLAYING);
    current_->syncState();
    paused_ = false;
}

bool AudioEngine::pipelinePlaying() const {
    if (!pipeline_) return false;
    GstState st = GST_STATE_NULL, pending = GST_STATE_VOID_PENDING;
    gst_element_get_state(pipeline_, &st, &pending, 0);
    return st == GST_STATE_PLAYING || pending == GST_STATE_PLAYING;
}

void AudioEngine::setSinkMuted(bool muted) {
    if (sinkVol_) g_object_set(sinkVol_, "mute", muted ? TRUE : FALSE, nullptr);
}

void AudioEngine::crossfadeTo(const QString& pathOrUri, double seconds, const QString& trackId) {
    // From pause it is a hard cut. There is nothing playing to fade out, and
    // the fade path never sets the pipeline playing: it would mark the engine
    // unpaused over a paused pipeline, silence that play cannot undo.
    if (!current_ || seconds <= 0 || pipelineErrored_ || paused_) { loadTrack(pathOrUri, trackId); return; }
    // A previous fade still running: finish it instantly.
    if (incoming_) {
        fadeTimer_.stop();
        incoming_->setVolume(1.0);
        retiring_.clear();
        retiring_.push_back(std::move(current_));
        promoteIncoming();
    }
    forgetReplacement();
    incoming_ = makeDeck(pathOrUri, /*deferLink=*/true);   // don't stall the mixer while buffering
    incomingTrack_ = trackId;
    if (videoPending_ && !videoPendingTrack_.isEmpty() && !trackId.isEmpty() && videoPendingTrack_ != trackId) {
        std::fprintf(stderr, "[%9.1f] [video] prerolled deck for %s dropped, fading to %s\n", meloLogMs(),
                     qPrintable(videoPendingTrack_), qPrintable(trackId));
        videoPending_.reset();
    }
    videoIncoming_ = std::move(videoPending_);
    videoPendingTrack_.clear();
    // only a prerolled deck dissolves from the outgoing picture
    dissolveOutgoing_ = videoIncoming_ && videoIncoming_->hasFrame();
    if (videoIncoming_) videoIncoming_->start();
    emit videoChanged();
    incoming_->setVolume(0.0);
    pendingIncomingSeek_ = -1;
    setSinkMuted(false);   // safety: never fade while the sink is muted
    // The fade starts only when the incoming deck actually produces audio —
    // starting on URL arrival fades the outgoing track into preroll silence.
    SourceDeck* raw = incoming_.get();
    std::fprintf(stderr, "[%9.1f] [xfade] deck created, waiting for first buffer (fade %.1fs)\n", meloLogMs(), seconds);
    incoming_->onFirstBuffer([this, raw, seconds] {
        std::fprintf(stderr, "[%9.1f] [xfade] first buffer from incoming deck\n", meloLogMs());
        QMetaObject::invokeMethod(this, [this, raw, seconds] {
            if (incoming_.get() != raw) {
                std::fprintf(stderr, "[%9.1f] [xfade] fade-start ignored: deck superseded\n", meloLogMs());
                return;
            }
            std::fprintf(stderr, "[%9.1f] [xfade] fade started\n", meloLogMs());
            if (pendingIncomingSeek_ >= 0) {   // silence-skip that raced preroll
                incoming_->seekTo(pendingIncomingSeek_);
                pendingIncomingSeek_ = -1;
            }
            fadePos_ = 0;
            fadeStep_ = 0.05 / seconds;   // 50 ms ticks
            fadeTimer_.start();
        }, Qt::QueuedConnection);
    });
    incoming_->syncState();
    paused_ = false;
}

void AudioEngine::onFadeTick() {
    fadePos_ += fadeStep_;
    const double p = std::min(fadePos_, 1.0);
    const double vOut = std::cos(p * M_PI / 2.0);   // equal-power
    const double vIn  = std::sin(p * M_PI / 2.0);
    if (current_)  current_->setVolume(vOut);
    if (incoming_) incoming_->setVolume(vIn);
    if (p >= 1.0) {
        std::fprintf(stderr, "[%9.1f] [xfade] fade complete\n", meloLogMs());
        fadeTimer_.stop();
        retiring_.push_back(std::move(current_));
        promoteIncoming();
        emit videoChanged();
        // Teardown of the faded-out deck: safe now that its volume is 0.
        retiring_.clear();
    }
}

void AudioEngine::promoteIncoming() {
    current_ = std::move(incoming_);
    currentTrack_ = std::move(incomingTrack_);
    incomingTrack_.clear();
    videoCurrent_ = std::move(videoIncoming_);
    clearHold();
}

void AudioEngine::stop() {
    dropVideoDecks();
    fadeTimer_.stop();
    forgetReplacement();
    incoming_.reset();
    retiring_.clear();
    current_.reset();
    currentTrack_.clear();
    incomingTrack_.clear();
    if (pipeline_) gst_element_set_state(pipeline_, GST_STATE_PAUSED);
}

void AudioEngine::setPaused(bool paused) {
    if (!pipeline_ || paused_ == paused) return;
    paused_ = paused;
    // a fade freezes with the audio and resumes with it
    if (paused) {
        if (fadeTimer_.isActive()) { fadeTimer_.stop(); fadeFrozen_ = true; }
    } else if (fadeFrozen_) {
        fadeFrozen_ = false;
        fadeTimer_.start();
    }
    if (!paused) setSinkMuted(false);   // a failed load must not leave resume silent
    gst_element_set_state(pipeline_, paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
}

void AudioEngine::finishFadeNow() {
    if (!incoming_) return;
    fadeTimer_.stop();
    fadeFrozen_ = false;
    if (current_) current_->setVolume(0.0);
    incoming_->setVolume(1.0);
    retiring_.push_back(std::move(current_));
    promoteIncoming();
    emit videoChanged();
    retiring_.clear();
    std::fprintf(stderr, "[%9.1f] [xfade] fade cut short\n", meloLogMs());
}

void AudioEngine::seekTo(double seconds, bool cutFade) {
    seekToDecks(seconds, cutFade);
    emit seeked();
}

void AudioEngine::seekToDecks(double seconds, bool cutFade) {
    const double s = std::max(0.0, seconds);
    if (incoming_ && incoming_.get() == replacing_) {
        pendingIncomingSeek_ = s;   // applied on its first buffer
        if (videoIncoming_) videoIncoming_->seekTo(videoPositionFor(s));
        return;
    }
    if (incoming_) {
        if (!cutFade) {
            // internal silence-skip: it targets the INCOMING track. Leave the
            // fade envelope alone; a deck still prerolling can't seek yet, so
            // park the position and apply it on its first buffer.
            if (!incoming_->seekTo(s)) pendingIncomingSeek_ = s;
            if (videoIncoming_) videoIncoming_->seekTo(videoPositionFor(s));
            return;
        }
        // user scrub during a crossfade = they took control of the incoming
        // track: cut the fade to full volume instead of staying half-quiet
        // and ramping (the outgoing deck retires immediately)
        finishFadeNow();
    }
    if (current_) current_->seekTo(s);
    if (videoCurrent_) videoCurrent_->seekTo(videoPositionFor(s));
}

std::unique_ptr<VideoDeck> AudioEngine::makeVideoDeck(const QString& url) {
    QString uri = url;
    if (!uri.contains("://")) uri = QUrl::fromLocalFile(url).toString();
    auto deck = std::make_unique<VideoDeck>(uri.toStdString(),
        videoPlanar_ ? VideoDeck::Output::Planar : VideoDeck::Output::Rgba);
    deck->onFirstFrame([this] {
        QMetaObject::invokeMethod(this, [this] { emit videoChanged(); }, Qt::QueuedConnection);
    });
    // a paused picture fetches from when the new place's frame is there, not from the seek
    deck->onSeekLanded([this] {
        QMetaObject::invokeMethod(this, [this] { emit seeked(); }, Qt::QueuedConnection);
    });
    return deck;
}

void AudioEngine::dropVideoDecks() {
    clearHold();
    const bool had = videoCurrent_ || videoIncoming_ || videoPending_;
    videoCurrent_.reset();
    videoIncoming_.reset();
    videoPending_.reset();
    videoPendingTrack_.clear();
    if (had) emit videoChanged();
}

// A video deck that errored is dropped; audio carries on without it.
void AudioEngine::dropFailedVideoDecks() {
    bool dropped = false;
    for (auto* d : {&videoCurrent_, &videoIncoming_, &videoPending_}) {
        if (*d && (*d)->failed()) {
            std::fprintf(stderr, "[%9.1f] [video] %s failed, dropping\n", meloLogMs(), (*d)->name());
            d->reset();
            dropped = true;
        }
    }
    if (dropped) emit videoChanged();
}

void AudioEngine::setVideoWanted(bool on) {
    videoWanted_ = on;
    if (!on) clearHold();
}

void AudioEngine::dropVideoDecksIfUnwanted() {
    if (!videoWanted_) dropVideoDecks();
}

void AudioEngine::attachVideo(const QString& url, bool incoming, const QString& trackId) {
    if (!videoWanted_) return;
    if (incoming) {
        logOutputLeadOnce();
        videoPending_ = makeVideoDeck(url);          // prerolls; bound at the next deck switch
        videoPendingTrack_ = trackId;
        return;
    }
    // "current" is whichever audio deck owns the position: the incoming one mid-fade
    SourceDeck* audio = incoming_ ? incoming_.get() : current_.get();
    if (!audio) return;
    const QString& playing = incoming_ ? incomingTrack_ : currentTrack_;
    if (!trackId.isEmpty() && trackId != playing) {
        std::fprintf(stderr, "[%9.1f] [video] attach for %s refused, playing %s\n", meloLogMs(),
                     qPrintable(trackId), qPrintable(playing));
        return;
    }
    logOutputLeadOnce();
    auto deck = makeVideoDeck(url);
    const double pos = audio->positionSeconds();
    if (pos > 0.05) deck->seekTo(videoPositionFor(pos));
    deck->start();
    if (incoming_) videoIncoming_ = std::move(deck);
    else videoCurrent_ = std::move(deck);
    emit videoChanged();
}

void AudioEngine::discardPendingVideo() { videoPending_.reset(); videoPendingTrack_.clear(); }

// the deck of the track that owns the position: the incoming one mid-fade
bool AudioEngine::hasVideoDeck() const { return incoming_ ? bool(videoIncoming_) : bool(videoCurrent_); }

AudioEngine::OutputLead AudioEngine::outputLeadParts() const {
    OutputLead l;
    if (audioQueue_) {
        guint64 ns = 0;
        g_object_get(audioQueue_, "max-size-time", &ns, nullptr);
        l.queue = double(ns) / GST_SECOND;
    }
    // The sink's own buffer is its buffer-time; get_latency is the pipeline's, a fallback only.
    if (audibleSink_ && g_object_class_find_property(G_OBJECT_GET_CLASS(audibleSink_), "buffer-time")) {
        gint64 us = 0;
        g_object_get(audibleSink_, "buffer-time", &us, nullptr);
        l.sink = double(us) / 1e6;
    } else if (audibleSink_ && GST_IS_BASE_SINK(audibleSink_)) {
        l.sink = double(gst_base_sink_get_latency(GST_BASE_SINK(audibleSink_))) / GST_SECOND;
    }
    return l;
}

double AudioEngine::outputLatencySeconds() const {
    const OutputLead l = outputLeadParts();
    return l.queue + l.sink;
}

void AudioEngine::logOutputLeadOnce() {
    if (outputLeadLogged_) return;
    outputLeadLogged_ = true;
    const OutputLead l = outputLeadParts();
    std::fprintf(stderr, "[%9.1f] [video] output lead: queue %d ms + sink %d ms (sync %+d ms)\n",
                 meloLogMs(), int(std::lround(l.queue * 1000)), int(std::lround(l.sink * 1000)), videoSyncMs_);
}

double AudioEngine::videoPositionFor(double audioSeconds) const {
    return std::max(0.0, audioSeconds - videoLeadSeconds());
}

VideoView AudioEngine::videoView() {
    dropFailedVideoDecks();
    VideoView v;
    v.trackId = incoming_ ? incomingTrack_ : currentTrack_;
    if (!videoCurrent_ && !videoIncoming_) { clearHold(); return v; }
    // Mid-fade the picture is the incoming track's; the outgoing one shows only
    // under it, and never again once the view has gone empty.
    if (incoming_) {
        if (videoIncoming_)
            if (auto f = videoIncoming_->frameAt(videoPositionFor(position()))) v.incoming = f->px;
        if (!v.incoming) { dissolveOutgoing_ = false; return v; }
        if (dissolveOutgoing_ && videoCurrent_ && current_)
            if (auto f = videoCurrent_->frameAt(videoPositionFor(current_->positionSeconds()))) v.main = f->px;
        v.mix = fadeProgress();
        if (!v.main) { v.main = v.incoming; v.incoming = nullptr; v.mix = 0; }
        return v;
    }
    if (videoCurrent_ && current_)
        if (auto f = videoCurrent_->frameAt(videoPositionFor(current_->positionSeconds()))) v.main = f->px;
    // a re-attach holds the last picture of the same track until the new deck's first frame
    if (v.main) { lastMainPixels_ = v.main; lastMainTrack_ = v.trackId; }
    else if (lastMainTrack_ == v.trackId) v.main = lastMainPixels_;
    return v;
}

void AudioEngine::setMasterVolume(double v) {
    const double vol = std::clamp(v, 0.0, 1.0);
    // v is the slider position on PulseAudio's cubic (perceptual) scale;
    // GStreamer's "volume" is linear gain. Cubing makes melo's percentage match
    // KDE's mixer and spreads usable levels across the slider's travel.
    const double gain = vol * vol * vol;
    if (sinkVol_)   // pulsesink: server-side, instant; fbvol: element fallback
        g_object_set(sinkVol_, "volume", gain, nullptr);
    if (vizVol_) g_object_set(vizVol_, "volume", gain, nullptr);
}

// isfinite guard: std::clamp(NaN, -24.0, 12.0) returns NaN, which would reach
// the equalizer's filter coefficients and silence the output. The state is
// stored even when the element is missing, so eqBands() reports the curve.
void AudioEngine::setEqBand(int band, double db) {
    if (band < 0 || band > 9 || !std::isfinite(db)) return;
    eqBands_[band] = std::clamp(db, -24.0, 12.0);
    if (!eq_) return;
    char prop[8];
    std::snprintf(prop, sizeof(prop), "band%d", band);
    // band0..band9 are Double: pass a double, never an integer literal.
    g_object_set(eq_, prop, eqBands_[band], nullptr);
}

// equalizer-10bands has no overall gain (band0..band9 and nothing else), so the
// preamp is a `volume` element ahead of it. dB in, linear at the property —
// +12 dB is 3.98, comfortably inside volume's 0..10 range.
void AudioEngine::setPreamp(double db) {
    if (!std::isfinite(db)) return;   // see setEqBand: the clamp will not do it
    preampDb_ = std::clamp(db, -12.0, 12.0);
    if (preampEl_) g_object_set(preampEl_, "volume", dbToLinearGain(preampDb_), nullptr);
}

std::array<double, 10> AudioEngine::eqBandGains() const {
    std::array<double, 10> gains = {0,0,0,0,0,0,0,0,0,0};
    if (!eq_) return gains;
    for (int i = 0; i < 10; ++i) {
        char prop[8];
        std::snprintf(prop, sizeof(prop), "band%d", i);
        g_object_get(eq_, prop, &gains[i], nullptr);
    }
    return gains;
}

double AudioEngine::preampLinearGain() const {
    if (!preampEl_) return -1;
    gdouble gain = -1;
    g_object_get(preampEl_, "volume", &gain, nullptr);
    return gain;
}

// g_object_set collects a float property as a double, so an integer literal
// (g_object_set(pan_, "panorama", 0, nullptr)) corrupts the value. The
// isfinite guard is needed because std::clamp(NaN, -1.0, 1.0) returns NaN.
void AudioEngine::setBalance(double v) {
    if (!std::isfinite(v)) return;
    balance_ = std::clamp(v, -1.0, 1.0);
    if (pan_) g_object_set(pan_, "panorama", static_cast<gfloat>(balance_), nullptr);
}

// A replacement deck still prerolling counts as the seek it carries.
bool AudioEngine::seekPending() const {
    if (incoming_ && incoming_.get() == replacing_) return true;
    const SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
    return d && d->seekPending();
}

double AudioEngine::position() const {
    if (incoming_ && incoming_.get() == replacing_) return pendingIncomingSeek_;
    const SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
    return d ? d->positionSeconds() : -1;
}

void AudioEngine::forgetReplacement() {
    replacing_ = replacement_ = stallReported_ = nullptr;
}

// A seek with no data for seekTimeoutMs_ cannot recover in its own deck: the
// demuxer holds it while the source is blocked, so a re-sent seek never
// reaches the source. The deck is replaced; a replacement that stalls too
// reports the track as failed, once.
void AudioEngine::watchStuckSeeks() {
    if (replacement_ && replacement_ != replacing_ && replacement_ == incoming_.get()
        && !incoming_->seekPending())
        replacement_ = nullptr;   // landed; a later stall is a new one
    if (replacement_ && replacement_ != replacing_ && replacement_ == current_.get()
        && !current_->seekPending())
        replacement_ = nullptr;
    if (replacing_ && replacing_ == incoming_.get()
        && meloLogMs() - replaceStartedMs_ >= seekTimeoutMs_) {
        reportStalled(incoming_.get(), meloLogMs() - replaceStartedMs_);
        return;
    }
    if (incoming_) {
        if (incoming_.get() != replacing_ && incoming_->seekWaitedMs() >= seekTimeoutMs_)
            replaceStuckDeck(true);
        return;   // a seek on the outgoing deck ends with the fade
    }
    if (current_ && current_->seekWaitedMs() >= seekTimeoutMs_) replaceStuckDeck(false);
}

void AudioEngine::reportStalled(SourceDeck* d, double waitedMs) {
    if (d == stallReported_) return;
    std::fprintf(stderr, "[%9.1f] [%s] replacement has no data after %.1f s; stream stalled\n",
                 meloLogMs(), GST_OBJECT_NAME(d->bin()), waitedMs / 1000.0);
    replacing_ = replacement_ = nullptr;
    stallReported_ = d;
    QMetaObject::invokeMethod(this, [this] { emit pipelineError(QStringLiteral("stream stalled")); },
                              Qt::QueuedConnection);
}

// The stuck deck is never relinked: a linked input with no data stalls the
// mixer. A fresh deck on the same URI fades in over it (0.3 s) and takes the
// newest target on its first buffer; the bound video deck stays bound.
void AudioEngine::replaceStuckDeck(bool isIncoming) {
    SourceDeck* stuck = isIncoming ? incoming_.get() : current_.get();
    const double waited = stuck->seekWaitedMs();
    if (stuck == replacement_) { reportStalled(stuck, waited); return; }
    if (stuck == stallReported_) return;
    const double target = std::max(0.0, stuck->requestedSeek());
    std::fprintf(stderr, "[%9.1f] [%s] seek to %.2f s has no data after %.1f s; replacing the deck\n",
                 meloLogMs(), GST_OBJECT_NAME(stuck->bin()), target, waited / 1000.0);
    replaceDuration_ = stuck->durationSeconds();
    auto deck = makeDeck(QString::fromStdString(stuck->uri()), /*deferLink=*/true);
    deck->setVolume(0.0);
    SourceDeck* raw = deck.get();
    fadeTimer_.stop();
    fadeFrozen_ = false;
    if (isIncoming) {
        // the outgoing deck holds its level; the fade resumes where it was
        retiring_.push_back(std::move(incoming_));
        incoming_ = std::move(deck);
    } else {
        incoming_ = std::move(deck);
        incomingTrack_ = currentTrack_;
        videoIncoming_ = std::move(videoCurrent_);
        dissolveOutgoing_ = false;
        fadePos_ = 0;
        fadeStep_ = 0.05 / 0.3;
    }
    pendingIncomingSeek_ = target;
    replacing_ = replacement_ = raw;
    replaceStartedMs_ = meloLogMs();
    incoming_->onFirstBuffer([this, raw] {
        QMetaObject::invokeMethod(this, [this, raw] {
            if (incoming_.get() != raw || replacing_ != raw) return;
            replacing_ = nullptr;
            if (pendingIncomingSeek_ >= 0) {
                incoming_->seekTo(pendingIncomingSeek_);
                pendingIncomingSeek_ = -1;
            }
            if (paused_) fadeFrozen_ = true;
            else fadeTimer_.start();
        }, Qt::QueuedConnection);
    });
    incoming_->syncState();
}
// Playing with the position still for 3 s: log the output's state once, and
// once more when it moves again.
void AudioEngine::watchStall(double pos) {
    if (std::abs(pos - stallPos_) > 0.01) {
        if (stallTicks_ >= 12)
            std::fprintf(stderr, "[%9.1f] [stall] moving again at %.2f s\n", meloLogMs(), pos);
        stallPos_ = pos;
        stallTicks_ = 0;
        return;
    }
    if (++stallTicks_ == 12) logStall();
}

void AudioEngine::logStall() const {
    const auto state = [](GstElement* e) {
        if (!e) return std::string("none");
        GstState cur = GST_STATE_VOID_PENDING, pend = GST_STATE_VOID_PENDING;
        const GstStateChangeReturn r = gst_element_get_state(e, &cur, &pend, 0);
        std::string s = gst_element_state_get_name(cur);
        if (pend != GST_STATE_VOID_PENDING) s += std::string("→") + gst_element_state_get_name(pend);
        if (r == GST_STATE_CHANGE_ASYNC) s += " (async)";
        if (r == GST_STATE_CHANGE_FAILURE) s += " (failed)";
        return s;
    };
    std::fprintf(stderr, "[%9.1f] [stall] position %.2f s still for 3 s; pipeline %s, sink %s, mixer at %.2f s%s\n",
                 meloLogMs(), stallPos_, state(pipeline_).c_str(), state(audibleSink_).c_str(),
                 mixerPositionSeconds(), pipelineErrored_ ? ", errored" : "");
    const auto deck = [&](const char* role, const SourceDeck* d) {
        if (d) std::fprintf(stderr, "[%9.1f] [stall]   %s %s: %s, at %.2f s\n", meloLogMs(), role, GST_OBJECT_NAME(d->bin()),
                            state(d->bin()).c_str(), d->positionSeconds());
    };
    deck("current", current_.get());
    deck("incoming", incoming_.get());
    for (const auto& r : retiring_) deck("retiring", r.get());
    if (!mixer_) return;
    GST_OBJECT_LOCK(mixer_);
    for (GList* l = GST_ELEMENT(mixer_)->sinkpads; l; l = l->next) {
        GstAggregatorPad* p = GST_AGGREGATOR_PAD(l->data);
        GstPad* peer = gst_pad_get_peer(GST_PAD(p));
        GstObject* from = peer ? gst_object_get_parent(GST_OBJECT(peer)) : nullptr;
        std::fprintf(stderr, "[%9.1f] [stall]   mixer %s from %s: %s%s\n", meloLogMs(), GST_OBJECT_NAME(p),
                     from ? GST_OBJECT_NAME(from) : "nothing",
                     gst_aggregator_pad_has_buffer(p) ? "buffer waiting" : "no buffer",
                     gst_aggregator_pad_is_eos(p) ? ", eos" : "");
        if (from) gst_object_unref(from);
        if (peer) gst_object_unref(peer);
    }
    GST_OBJECT_UNLOCK(mixer_);
}

double AudioEngine::mixerPositionSeconds() const {
    gint64 pos = 0;
    if (mixer_ && gst_element_query_position(mixer_, GST_FORMAT_TIME, &pos))
        return double(pos) / GST_SECOND;
    return -1;
}
double AudioEngine::duration() const {
    if (incoming_ && incoming_.get() == replacing_) return replaceDuration_;
    const SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
    return d ? d->durationSeconds() : -1;
}

GstFlowReturn AudioEngine::onNewSample(GstAppSink* sink, gpointer user) {
    auto* self = static_cast<AudioEngine*>(user);
    GstSample* sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;
    GstBuffer* buf = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (buf && gst_buffer_map(buf, &map, GST_MAP_READ)) {
        const float* f = reinterpret_cast<const float*>(map.data);
        const std::size_t n = map.size / sizeof(float);
        self->vizQueue_.push(f, n);
        SpectrumSource::feed(f, n);   // audio-reactive backgrounds tap
        gst_buffer_unmap(buf, &map);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}
