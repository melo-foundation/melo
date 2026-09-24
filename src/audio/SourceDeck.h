#pragma once
#include <gst/gst.h>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>

// One audio source as a self-contained GstBin:
//   uridecodebin -> audioconvert -> audioresample -> capsfilter(F32LE/48000/2ch) -> volume
// exposed via a ghost src pad, linked into a shared audiomixer.
class SourceDeck {
public:
    // deferLink=true: don't link into the mixer yet — block the output pad,
    // preroll detached, and link on the first ready buffer (offset computed
    // then). Prevents the mixer stalling ALL audio while this deck buffers.
    SourceDeck(GstElement* pipeline, GstElement* mixer, const std::string& uri,
               bool deferLink = false);
    ~SourceDeck();

    void setVolume(double v);
    // Shift this deck's timeline so PTS 0 lands at `runningTime` in the mixer's
    // timeline — required when starting a deck on an already-running pipeline.
    void setStartOffset(GstClockTime runningTime);
    // Fires (on a GStreamer thread!) when this deck's stream hits EOS.
    void onEos(std::function<void()> cb);
    // Fires ONCE (on a GStreamer thread!) when the first audio buffer leaves
    // this deck — i.e. it can actually be heard now.
    void onFirstBuffer(std::function<void()> cb);
    // A scrub received while a network seek is still detached is coalesced;
    // this callback asks the owner to resume it on the main thread.
    void onReseekNeeded(std::function<void()> cb);
    bool continuePendingSeek();
    void syncState();

    double positionSeconds() const;   // -1 if unknown
    double durationSeconds() const;   // -1 if unknown
    bool seekTo(double seconds);      // flushing seek on this deck only

    GstElement* bin() const { return bin_; }

    // The engine's master timeline (mixer output position; clock fallback).
    GstClockTime mixerTimelineNow() const;

    // Wait (bounded) for the detached teardown workers ~SourceDeck spawns —
    // call once before Qt teardown begins (see main), else they race
    // ~QGuiApplication's heap ops and the exit aborts in malloc.
    static void joinAllTeardowns();

private:
    static void onPadAdded(GstElement* decode, GstPad* pad, gpointer user);
    // Why the probes do not get `this`: every callback below runs on a
    // GStreamer streaming thread and dereferences the deck, and
    // gst_pad_remove_probe() does not wait for a running callback
    // (cleanup_hook() defers the free, no join). The pad-added signal is the
    // same, since the element outlives the deck. A callback holds this mutex
    // for its whole body; the destructor takes it and nulls `self` before
    // touching a probe, so a running callback finishes first and a later one
    // does nothing. Safe across eosCb_/firstBufCb_: both marshal to the GUI
    // thread and cannot re-enter ~SourceDeck.
    struct Liveness {
        std::mutex m;
        SourceDeck* self = nullptr;
    };
    struct DeckLock {
        std::shared_ptr<Liveness> ref;
        std::unique_lock<std::mutex> lk;
        SourceDeck* self;
        explicit DeckLock(gpointer user)
            : ref(*static_cast<std::shared_ptr<Liveness>*>(user)),
              lk(ref->m), self(ref->self) {}
    };
    std::shared_ptr<Liveness> live_ = std::make_shared<Liveness>();

    // Each registration owns a heap shared_ptr copy, freed by GStreamer via
    // releaseLiveRef, so the control block outlives any in-flight callback.
    gpointer newLiveRef();
    static void releaseLiveRef(gpointer p);

    static GstPadProbeReturn eosProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    static GstPadProbeReturn firstBufProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    static GstPadProbeReturn readyProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    static GstPadProbeReturn seekSegmentProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    static GstPadProbeReturn seekOffsetProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    void linkToMixer(bool withOffset);
    void unlinkFromMixer();
    bool sendSeek(double seconds);
    void restoreAfterFailedSeek();

    GstElement* pipeline_ = nullptr;
    GstElement* mixer_    = nullptr;
    GstElement* bin_      = nullptr;
    GstElement* convert_  = nullptr;
    GstElement* volume_   = nullptr;
    GstPad*     ghostSrc_ = nullptr;
    GstPad*     mixerPad_ = nullptr;
    gulong      eosProbeId_ = 0;
    gulong      firstBufProbeId_ = 0;
    gulong      blockProbeId_ = 0;
    gulong      seekSegmentProbeId_ = 0;
    gulong      seekProbeId_ = 0;
    std::atomic_bool seekSegmentSeen_{false};
    mutable std::mutex seekMutex_;
    double requestedSeek_ = -1;
    double inFlightSeek_ = -1;
    bool seekInFlight_ = false;
    bool reseekPosted_ = false;
    std::function<void()> eosCb_;
    std::function<void()> firstBufCb_;
    std::function<void()> reseekCb_;
};
