#include "SourceDeck.h"
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include "../core/LogClock.h"

namespace {
/** One-shot: log the instant the first decoded buffer leaves the deck. The
 *  deferLink path reports this from readyProbe; this covers the direct-link
 *  path, which otherwise produced no FIRST AUDIO marker at all. */
GstPadProbeReturn meloFirstAudioProbe(GstPad*, GstPadProbeInfo*, gpointer) {
    std::fprintf(stderr, "[%9.1f] [timing] FIRST AUDIO\n", meloLogMs());
    return GST_PAD_PROBE_REMOVE;
}
}  // namespace

// In-flight detached teardown workers. They race process exit: gst object
// frees concurrent with ~QGuiApplication's shutdown corrupt the heap (exit
// SIGABRT in malloc). joinAllTeardowns() waits (bounded) before Qt teardown
// begins.
static std::mutex s_teardownMutex;
static std::condition_variable s_teardownsCv;
static int s_teardownsActive = 0;

SourceDeck::SourceDeck(GstElement* pipeline, GstElement* mixer, const std::string& uri,
                       bool deferLink)
    : pipeline_(pipeline), mixer_(mixer) {
    static int n = 0;
    const int id = n++;
    auto nm = [&](const char* base) { return std::string(base) + std::to_string(id); };

    bin_ = gst_bin_new(nm("deck").c_str());

    GstElement* decode  = gst_element_factory_make("uridecodebin", nm("dec").c_str());
    convert_            = gst_element_factory_make("audioconvert", nm("conv").c_str());
    GstElement* resample= gst_element_factory_make("audioresample", nm("resamp").c_str());
    GstElement* capsf   = gst_element_factory_make("capsfilter", nm("caps").c_str());
    volume_             = gst_element_factory_make("volume", nm("vol").c_str());

    g_object_set(decode, "uri", uri.c_str(), nullptr);

    GstCaps* caps = gst_caps_from_string(
        "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved");
    g_object_set(capsf, "caps", caps, nullptr);
    gst_caps_unref(caps);

    gst_bin_add_many(GST_BIN(bin_), decode, convert_, resample, capsf, volume_, nullptr);
    gst_element_link_many(convert_, resample, capsf, volume_, nullptr);
    g_signal_connect_data(decode, "pad-added", G_CALLBACK(onPadAdded), newLiveRef(),
                          [](gpointer d, GClosure*) { releaseLiveRef(d); }, GConnectFlags(0));

    GstPad* volSrc = gst_element_get_static_pad(volume_, "src");
    ghostSrc_ = gst_ghost_pad_new("src", volSrc);
    gst_pad_set_active(ghostSrc_, TRUE);
    gst_element_add_pad(bin_, ghostSrc_);
    gst_object_unref(volSrc);

    // EOS detection for auto-advance: event probe on the ghost pad.
    eosProbeId_ = gst_pad_add_probe(ghostSrc_, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM,
                                    &SourceDeck::eosProbe, newLiveRef(), &SourceDeck::releaseLiveRef);

    gst_bin_add(GST_BIN(pipeline_), bin_);

    if (deferLink) {
        // Block the output BEFORE any data can flow; readyProbe links into
        // the mixer (with an accurate offset) once the first buffer is ready.
        // Linking earlier stalls the WHOLE mixer while this deck buffers.
        blockProbeId_ = gst_pad_add_probe(ghostSrc_,
            (GstPadProbeType)(GST_PAD_PROBE_TYPE_BLOCK | GST_PAD_PROBE_TYPE_BUFFER),
            &SourceDeck::readyProbe, newLiveRef(), &SourceDeck::releaseLiveRef);
    } else {
        linkToMixer(false);   // caller sets the offset (setStartOffset)
        gst_pad_add_probe(ghostSrc_, GST_PAD_PROBE_TYPE_BUFFER,
                          &meloFirstAudioProbe, nullptr, nullptr);
    }

    std::fprintf(stderr, "[%9.1f] [deck%d] built for %.90s%s\n", meloLogMs(), id, uri.c_str(),
                 deferLink ? " (deferred link)" : "");

    // Last: probes registered above can already be firing, and until this is
    // set they see a null self and do nothing. Construction is not finished
    // until it is, which is exactly the window this closes.
    { std::lock_guard<std::mutex> lk(live_->m); live_->self = this; }
}

// The mixer's output position is the engine's master timeline (the sink runs
// sync=false, see AudioEngine::buildPipeline) and every offset pin references
// it; pinning to the wall clock desyncs when the mixer stalls on a starved
// branch. Clock running time is the fallback before the mixer has output.
GstClockTime SourceDeck::mixerTimelineNow() const {
    gint64 pos = 0;
    if (mixer_ && gst_element_query_position(mixer_, GST_FORMAT_TIME, &pos) && pos >= 0)
        return (GstClockTime)pos;
    if (GstClock* clock = gst_element_get_clock(pipeline_)) {
        const GstClockTime rt =
            gst_clock_get_time(clock) - gst_element_get_base_time(pipeline_);
        gst_object_unref(clock);
        return rt;
    }
    return 0;
}

void SourceDeck::linkToMixer(bool withOffset) {
    if (withOffset)
        gst_pad_set_offset(ghostSrc_, (gint64)mixerTimelineNow());
    mixerPad_ = gst_element_request_pad_simple(mixer_, "sink_%u");
    if (gst_pad_link(ghostSrc_, mixerPad_) != GST_PAD_LINK_OK)
        std::fprintf(stderr, "[deck] FAILED to link to mixer\n");
}

void SourceDeck::unlinkFromMixer() {
    if (!mixerPad_) return;
    gst_pad_unlink(ghostSrc_, mixerPad_);
    gst_element_release_request_pad(mixer_, mixerPad_);
    gst_object_unref(mixerPad_);
    mixerPad_ = nullptr;
}

// Streaming thread, pad blocked with the first buffer pending: link into the
// mixer NOW (offset = current running time) and unblock. This is the
// canonical add-a-branch-without-stalling-the-aggregator recipe.
gpointer SourceDeck::newLiveRef() {
    return new std::shared_ptr<Liveness>(live_);
}
void SourceDeck::releaseLiveRef(gpointer p) {
    delete static_cast<std::shared_ptr<Liveness>*>(p);
}

// Locks the deck alive for the body of a callback. `self` is null when the
// deck has already gone, which is the normal outcome of a probe that fires
// during teardown. Declared in the header beside Liveness so the static
// callbacks, which are members, can reach both.

GstPadProbeReturn SourceDeck::readyProbe(GstPad*, GstPadProbeInfo*, gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return GST_PAD_PROBE_REMOVE;
    // First decoded buffer is ready — this is the instant audio begins.
    std::fprintf(stderr, "[%9.1f] [timing] FIRST AUDIO\n", meloLogMs());
    self->blockProbeId_ = 0;
    self->linkToMixer(true);
    if (self->firstBufCb_) {
        auto cb = std::move(self->firstBufCb_);
        self->firstBufCb_ = nullptr;
        cb();   // NB: GStreamer streaming thread — marshal in the receiver
    }
    return GST_PAD_PROBE_REMOVE;
}

SourceDeck::~SourceDeck() {
    // Must run before the probe removals: taking this lock waits out a callback
    // already running on a streaming thread, and nulling self makes later ones
    // return. gst_pad_remove_probe() does not join, so removal alone is unsafe.
    { std::lock_guard<std::mutex> lk(live_->m); live_->self = nullptr; }

    eosCb_ = nullptr;
    if (!bin_) return;

    // Housekeeping (see above): remove the probes before the bin outlives us
    // on the teardown thread.
    if (eosProbeId_) gst_pad_remove_probe(ghostSrc_, eosProbeId_);
    if (firstBufProbeId_) gst_pad_remove_probe(ghostSrc_, firstBufProbeId_);
    if (blockProbeId_) gst_pad_remove_probe(ghostSrc_, blockProbeId_);
    if (seekSegmentProbeId_) gst_pad_remove_probe(ghostSrc_, seekSegmentProbeId_);
    if (seekProbeId_) gst_pad_remove_probe(ghostSrc_, seekProbeId_);

    // Detach from the mixer FIRST (fast, non-blocking): pending pushes return
    // NOT_LINKED and the mixer stops aggregating this pad immediately.
    unlinkFromMixer();

    // NULL-ing the bin waits for its streaming threads — a network source
    // stuck in a read (stale/throttled stream URL) blocks that transition
    // indefinitely. NEVER on the GUI thread: hand the bin to a detached
    // worker for the state change + final unref.
    gst_object_ref(bin_);
    gst_bin_remove(GST_BIN(pipeline_), bin_);   // drops the pipeline's ref
    GstElement* bin = bin_;
    bin_ = nullptr;
    {
        std::lock_guard<std::mutex> l(s_teardownMutex);
        ++s_teardownsActive;
    }
    std::thread([bin] {
        gst_element_set_state(bin, GST_STATE_NULL);
        gst_object_unref(bin);
        std::lock_guard<std::mutex> l(s_teardownMutex);
        if (--s_teardownsActive == 0) s_teardownsCv.notify_all();
    }).detach();
}

void SourceDeck::joinAllTeardowns() {
    std::unique_lock<std::mutex> l(s_teardownMutex);
    if (!s_teardownsCv.wait_for(l, std::chrono::seconds(5),
                                [] { return s_teardownsActive == 0; }))
        std::fprintf(stderr, "[deck] %d teardown worker(s) still busy at exit\n",
                     s_teardownsActive);
}

void SourceDeck::syncState() {
    gst_element_sync_state_with_parent(bin_);
}

void SourceDeck::setVolume(double v) {
    if (volume_) g_object_set(volume_, "volume", v, nullptr);
}

void SourceDeck::setStartOffset(GstClockTime runningTime) {
    if (ghostSrc_) gst_pad_set_offset(ghostSrc_, (gint64)runningTime);
}

void SourceDeck::onEos(std::function<void()> cb) {
    eosCb_ = std::move(cb);
}

void SourceDeck::onFirstBuffer(std::function<void()> cb) {
    firstBufCb_ = std::move(cb);
    // Deferred-link decks fire the callback from readyProbe at link time;
    // immediately-linked decks watch for the first buffer flowing.
    if (!blockProbeId_)
        firstBufProbeId_ = gst_pad_add_probe(ghostSrc_, GST_PAD_PROBE_TYPE_BUFFER,
                                             &SourceDeck::firstBufProbe, newLiveRef(), &SourceDeck::releaseLiveRef);
}

void SourceDeck::onReseekNeeded(std::function<void()> cb) {
    reseekCb_ = std::move(cb);
}

double SourceDeck::positionSeconds() const {
    // A network seek completes asynchronously, and until its first buffer the
    // pipeline reports the pre-seek position, which would walk the progress
    // bar back. The target is reported while the seek is in flight.
    {
        std::lock_guard<std::mutex> lock(seekMutex_);
        if (seekInFlight_) return requestedSeek_;
    }
    gint64 pos = 0;
    if (bin_ && gst_element_query_position(bin_, GST_FORMAT_TIME, &pos))
        return double(pos) / GST_SECOND;
    return -1;
}

double SourceDeck::durationSeconds() const {
    gint64 dur = 0;
    if (bin_ && gst_element_query_duration(bin_, GST_FORMAT_TIME, &dur))
        return double(dur) / GST_SECOND;
    return -1;
}

bool SourceDeck::sendSeek(double seconds) {
    // ACCURATE, not KEY_UNIT: audio keyframes can be seconds apart, so
    // key-unit seeks land a few seconds off the scrub target.
    return gst_element_seek_simple(bin_, GST_FORMAT_TIME,
        (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE),
        gint64(seconds * GST_SECOND));
}

void SourceDeck::restoreAfterFailedSeek() {
    gulong segmentProbe = 0;
    gulong bufferProbe = 0;
    {
        std::lock_guard<std::mutex> lock(seekMutex_);
        seekInFlight_ = false;
        reseekPosted_ = false;
        segmentProbe = seekSegmentProbeId_;
        bufferProbe = seekProbeId_;
        seekSegmentProbeId_ = 0;
        seekProbeId_ = 0;
    }
    // Probe removal can wait for an active callback; never do it while
    // holding seekMutex_, which that same callback takes.
    if (segmentProbe) gst_pad_remove_probe(ghostSrc_, segmentProbe);
    if (bufferProbe) gst_pad_remove_probe(ghostSrc_, bufferProbe);
    if (!mixerPad_) linkToMixer(true);   // restore the still-current stream
}

bool SourceDeck::seekTo(double seconds) {
    if (!bin_) return false;

    bool wasLinked = false;
    {
        std::lock_guard<std::mutex> lock(seekMutex_);
        requestedSeek_ = seconds;
        // Do not stack network seeks. Once the current request produces its
        // first buffer, seekOffsetProbe asks the main thread to issue only the
        // newest target while the branch remains safely detached.
        if (seekInFlight_) return true;
        wasLinked = mixerPad_ != nullptr;
        if (wasLinked) {
            seekInFlight_ = true;
            inFlightSeek_ = seconds;
        }
    }

    // A flushing seek must not reach audiomixer: it resets the shared timeline
    // and interrupts the other deck mid-crossfade. Dropping FLUSH_START at
    // ghostSrc_ can deadlock GStreamer 1.20 (an internal queue waits on a src
    // task stuck in a sink that never saw the flush), so the whole branch is
    // detached: its flush ends at the unlinked ghost pad, and the new
    // segment's first buffer links it back.
    if (wasLinked) {
        seekSegmentSeen_.store(false, std::memory_order_release);
        unlinkFromMixer();
        seekSegmentProbeId_ = gst_pad_add_probe(ghostSrc_,
            GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM,
            &SourceDeck::seekSegmentProbe, newLiveRef(), &SourceDeck::releaseLiveRef);
        seekProbeId_ = gst_pad_add_probe(ghostSrc_,
            (GstPadProbeType)(GST_PAD_PROBE_TYPE_BLOCK | GST_PAD_PROBE_TYPE_BUFFER),
            &SourceDeck::seekOffsetProbe, newLiveRef(), &SourceDeck::releaseLiveRef);
    }

    const bool ok = sendSeek(seconds);
    if (!ok && wasLinked) restoreAfterFailedSeek();
    return ok;
}

bool SourceDeck::continuePendingSeek() {
    double target;
    {
        std::lock_guard<std::mutex> lock(seekMutex_);
        if (!seekInFlight_) return false;
        target = requestedSeek_;
        inFlightSeek_ = target;
        reseekPosted_ = false;
        // The old request's SEGMENT already reached the probe. Wait for the
        // replacement request's segment before accepting another buffer.
        seekSegmentSeen_.store(false, std::memory_order_release);
    }
    const bool ok = sendSeek(target);
    if (!ok) restoreAfterFailedSeek();
    return ok;
}

GstPadProbeReturn SourceDeck::seekSegmentProbe(GstPad*, GstPadProbeInfo* info,
                                               gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return GST_PAD_PROBE_REMOVE;
    GstEvent* ev = GST_PAD_PROBE_INFO_EVENT(info);
    if (ev && GST_EVENT_TYPE(ev) == GST_EVENT_SEGMENT)
        self->seekSegmentSeen_.store(true, std::memory_order_release);
    return GST_PAD_PROBE_OK;
}

// Streaming thread, first buffer belonging to the post-seek SEGMENT blocked
// at the detached ghost pad. Rejoin at the mixer's position measured NOW, so
// a network stall costs only its real duration and never becomes PTS catch-up.
GstPadProbeReturn SourceDeck::seekOffsetProbe(GstPad*, GstPadProbeInfo* info, gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return GST_PAD_PROBE_REMOVE;
    if (!self->seekSegmentSeen_.load(std::memory_order_acquire))
        return GST_PAD_PROBE_DROP;   // stale pre-seek buffer; keep the probe

    std::function<void()> reseek;
    {
        std::lock_guard<std::mutex> lock(self->seekMutex_);
        if (!self->seekInFlight_) {
            self->seekProbeId_ = 0;
            return GST_PAD_PROBE_REMOVE;   // failed seek is restoring the link
        }
        if (self->requestedSeek_ != self->inFlightSeek_ && self->reseekCb_) {
            // A newer scrub arrived while this network request was pending.
            // Drop this response and ask the Qt thread to seek again; calling
            // a flushing seek from this streaming callback would deadlock.
            self->seekSegmentSeen_.store(false, std::memory_order_release);
            if (!self->reseekPosted_) {
                self->reseekPosted_ = true;
                reseek = self->reseekCb_;
            }
        } else {
            self->seekInFlight_ = false;
            self->reseekPosted_ = false;
            self->seekProbeId_ = 0;
            if (self->seekSegmentProbeId_) {
                gst_pad_remove_probe(self->ghostSrc_, self->seekSegmentProbeId_);
                self->seekSegmentProbeId_ = 0;
            }
            const GstClockTime now = self->mixerTimelineNow();
            self->linkToMixer(true);
            GstBuffer* buf = GST_PAD_PROBE_INFO_BUFFER(info);
            std::fprintf(stderr,
                         "[deck] post-seek rejoin: timeline=%.2f bufPts=%.2f\n",
                         double(now) / GST_SECOND,
                         buf ? double(GST_BUFFER_PTS(buf)) / GST_SECOND : -1.0);
            return GST_PAD_PROBE_REMOVE;
        }
    }
    if (reseek) reseek();
    return GST_PAD_PROBE_DROP;
}

void SourceDeck::onPadAdded(GstElement* /*decode*/, GstPad* pad, gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return;
    GstCaps* caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, nullptr);
    const gchar* name = caps ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : "";
    const bool isAudio = name && g_str_has_prefix(name, "audio/");
    if (caps) gst_caps_unref(caps);
    if (!isAudio) return;

    GstPad* sink = gst_element_get_static_pad(self->convert_, "sink");
    if (!gst_pad_is_linked(sink))
        gst_pad_link(pad, sink);
    gst_object_unref(sink);
}

GstPadProbeReturn SourceDeck::eosProbe(GstPad*, GstPadProbeInfo* info, gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return GST_PAD_PROBE_REMOVE;
    GstEvent* ev = GST_PAD_PROBE_INFO_EVENT(info);
    if (ev && GST_EVENT_TYPE(ev) == GST_EVENT_EOS && self->eosCb_)
        self->eosCb_();   // NB: GStreamer streaming thread — marshal in the receiver
    return GST_PAD_PROBE_OK;
}

GstPadProbeReturn SourceDeck::firstBufProbe(GstPad*, GstPadProbeInfo*, gpointer user) {
    DeckLock g(user);
    SourceDeck* self = g.self;
    if (!self) return GST_PAD_PROBE_REMOVE;
    self->firstBufProbeId_ = 0;   // self-removing one-shot
    if (self->firstBufCb_) {
        auto cb = std::move(self->firstBufCb_);
        self->firstBufCb_ = nullptr;
        cb();   // NB: GStreamer streaming thread — marshal in the receiver
    }
    return GST_PAD_PROBE_REMOVE;
}
