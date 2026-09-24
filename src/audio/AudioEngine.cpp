#include "AudioEngine.h"
#include "SourceDeck.h"
#include "PcmQueue.h"
#include "SpectrumSource.h"

#include <gst/audio/streamvolume.h>

#include <QUrl>
#include <algorithm>
#include <cmath>
#include <cstdio>

AudioEngine::AudioEngine(PcmQueue& vizQueue, QObject* parent)
    : QObject(parent), vizQueue_(vizQueue) {
    buildPipeline();

    posTimer_.setInterval(250);
    connect(&posTimer_, &QTimer::timeout, this, [this] {
        // The INCOMING deck owns the display as soon as a crossfade begins:
        // progress tracks the new song, not the fading one.
        SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
        if (!d || paused_) return;
        emit positionTick(d->positionSeconds(), d->durationSeconds());
    });
    posTimer_.start();

    fadeTimer_.setInterval(50);
    connect(&fadeTimer_, &QTimer::timeout, this, &AudioEngine::onFadeTick);
}

AudioEngine::~AudioEngine() {
    if (pipeline_) {
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        current_.reset();
        incoming_.reset();
        retiring_.clear();
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
    else std::fprintf(stderr, "[audio] audiopanorama unavailable — balance disabled\n");
    const auto build = [&err, &panStage](const QString& sink) {
        g_clear_error(&err);
        return gst_parse_launch(QStringLiteral(
            "audiomixer name=mix ! volume name=preamp ! equalizer-10bands name=eq ! %2tee name=t "
            "t. ! queue max-size-time=40000000 max-size-buffers=0 max-size-bytes=0 "
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
        std::fprintf(stderr, "[audio] pulsesink will not open a device — falling back to autoaudiosink\n");

    pipeline_ = (fakeSink || pulseUsable)
        ? build(fakeSink ? "fakesink sync=true"
                         : "pulsesink name=asink sync=false buffer-time=80000 latency-time=20000")
        : nullptr;
    // Fallback keeps a volume element in the audio branch (buffered but correct).
    if (!pipeline_ && !fakeSink) pipeline_ = build("volume name=fbvol ! autoaudiosink");
    if (!pipeline_) {
        std::fprintf(stderr, "[audio] pipeline build failed: %s\n", err ? err->message : "?");
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
    std::fprintf(stderr, "[audio] volume applies at: %s\n",
                 sinkVol_ ? GST_OBJECT_NAME(sinkVol_) : "NONE (fakesink test build)");
    appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "viz");

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
        auto* self = static_cast<AudioEngine*>(user);
        if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
            GError* e = nullptr; gchar* dbg = nullptr;
            gst_message_parse_error(msg, &e, &dbg);
            std::fprintf(stderr, "[bus] ERROR from %s: %s | %s\n",
                         GST_OBJECT_NAME(msg->src), e->message, dbg ? dbg : "");
            QMetaObject::invokeMethod(self, [self, m = QString::fromUtf8(e->message)] {
                self->pipelineErrored_ = true;   // next loadTrack does a full NULL reset
                emit self->pipelineError(m);
            }, Qt::QueuedConnection);
            g_error_free(e); g_free(dbg);
        }
        return TRUE;
    }, this);
    gst_object_unref(bus);
}

// True when the element that posted a message sits inside the deck that is
// currently playing (or is the pipeline itself, which nothing else owns).
// Anything from a retiring or incoming deck is somebody else's problem.
bool AudioEngine::messageIsFromCurrentDeck(GstObject* src) const {
    if (!src) return true;
    if (GST_ELEMENT_CAST(src) == pipeline_) return true;
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

void AudioEngine::loadTrack(const QString& pathOrUri) {
    fadeTimer_.stop();
    incoming_.reset();
    retiring_.clear();      // hard cut: tear down everything old
    current_.reset();
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

void AudioEngine::crossfadeTo(const QString& pathOrUri, double seconds) {
    // From pause it is a hard cut. There is nothing playing to fade out, and
    // the fade path never sets the pipeline playing: it would mark the engine
    // unpaused over a paused pipeline, silence that play cannot undo.
    if (!current_ || seconds <= 0 || pipelineErrored_ || paused_) { loadTrack(pathOrUri); return; }
    // A previous fade still running: finish it instantly.
    if (incoming_) {
        fadeTimer_.stop();
        incoming_->setVolume(1.0);
        retiring_.clear();
        retiring_.push_back(std::move(current_));
        current_ = std::move(incoming_);
    }
    incoming_ = makeDeck(pathOrUri, /*deferLink=*/true);   // don't stall the mixer while buffering
    incoming_->setVolume(0.0);
    pendingIncomingSeek_ = -1;
    setSinkMuted(false);   // safety: never fade while the sink is muted
    // The fade starts only when the incoming deck actually produces audio —
    // starting on URL arrival fades the outgoing track into preroll silence.
    SourceDeck* raw = incoming_.get();
    std::fprintf(stderr, "[xfade] deck created, waiting for first buffer (fade %.1fs)\n", seconds);
    incoming_->onFirstBuffer([this, raw, seconds] {
        std::fprintf(stderr, "[xfade] first buffer from incoming deck\n");
        QMetaObject::invokeMethod(this, [this, raw, seconds] {
            if (incoming_.get() != raw) {
                std::fprintf(stderr, "[xfade] fade-start ignored: deck superseded\n");
                return;
            }
            std::fprintf(stderr, "[xfade] fade started\n");
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
        std::fprintf(stderr, "[xfade] fade complete\n");
        fadeTimer_.stop();
        retiring_.push_back(std::move(current_));
        current_ = std::move(incoming_);
        // Teardown of the faded-out deck: safe now that its volume is 0.
        retiring_.clear();
    }
}

void AudioEngine::stop() {
    fadeTimer_.stop();
    incoming_.reset();
    retiring_.clear();
    current_.reset();
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
    current_ = std::move(incoming_);
    retiring_.clear();
    std::fprintf(stderr, "[xfade] fade cut short\n");
}

void AudioEngine::seekTo(double seconds, bool cutFade) {
    const double s = std::max(0.0, seconds);
    if (incoming_) {
        if (!cutFade) {
            // internal silence-skip: it targets the INCOMING track. Leave the
            // fade envelope alone; a deck still prerolling can't seek yet, so
            // park the position and apply it on its first buffer.
            if (!incoming_->seekTo(s)) pendingIncomingSeek_ = s;
            return;
        }
        // user scrub during a crossfade = they took control of the incoming
        // track: cut the fade to full volume instead of staying half-quiet
        // and ramping (the outgoing deck retires immediately)
        finishFadeNow();
    }
    if (current_) current_->seekTo(s);
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

double AudioEngine::position() const {
    const SourceDeck* d = incoming_ ? incoming_.get() : current_.get();
    return d ? d->positionSeconds() : -1;
}
double AudioEngine::mixerPositionSeconds() const {
    gint64 pos = 0;
    if (mixer_ && gst_element_query_position(mixer_, GST_FORMAT_TIME, &pos))
        return double(pos) / GST_SECOND;
    return -1;
}
double AudioEngine::duration() const {
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
