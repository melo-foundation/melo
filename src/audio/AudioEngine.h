#pragma once
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include "VideoFrameSource.h"
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>

class PcmQueue;
class SourceDeck;
class VideoDeck;

// GStreamer's `volume` takes a linear multiplier (1.0 = unity) and Winamp's
// preamp is dB, so dB is stored and converted only at the property. Amplitude
// ratio, hence /20; /10 would double every boost.
inline double dbToLinearGain(double db) { return std::pow(10.0, db / 20.0); }

// GStreamer engine. Static chain:
//   audiomixer -> volume(preamp) -> equalizer-10bands -> audiopanorama(balance) -> tee
//     -> {queue -> audioconvert -> pulsesink(master volume),
//         queue -> volume(viz) -> appsink}
// The preamp is its own `volume` element, ahead of the bands as in Winamp,
// because equalizer-10bands has no overall gain (tst_audioengine asserts it).
// Without pulsesink the branch ends in volume(master) -> autoaudiosink; either
// way master volume is downstream of balance. audiopanorama is optional.
// Tracks play on SourceDeck bins feeding the mixer; two live decks during crossfade.
// Emits position/duration/EOS so PlaybackCoordinator owns all sequencing policy.
class AudioEngine : public QObject, public VideoFrameSource {
    Q_OBJECT
public:
    explicit AudioEngine(PcmQueue& vizQueue, QObject* parent = nullptr);
    ~AudioEngine() override;

    // Hard-cut load: tears down current deck, starts the new URI immediately.
    // cutFade: a USER scrub finishes an in-flight crossfade (they took
    // control); internal seeks (silence skipStart) pass false and seek the
    // incoming deck without disturbing the fade envelope.
    void seekTo(double seconds, bool cutFade = true);
    void loadTrack(const QString& pathOrUri, const QString& trackId = {});
    // Crossfade: new deck fades in over `seconds` while current fades out.
    void crossfadeTo(const QString& pathOrUri, double seconds, const QString& trackId = {});
    void stop();                          // tear down all decks

    void setPaused(bool paused);
    bool paused() const { return paused_; }
    // complete an in-flight crossfade instantly (incoming to full volume,
    // outgoing retired) — a seek means the user took control of the track
    void finishFadeNow();
    void setMasterVolume(double v);       // 0..1 (sink stream volume: instant; viz element mirrors)
    void setEqBand(int band, double db);  // absolute dB, -24..+12
    // The EQ curve the engine applies, in dB, and its only copy: MeloUi.eq.bands
    // reads through to here, so melo's EQ window, applyEqConfig and plugins all
    // write and see the same array.
    std::array<double, 10> eqBands() const { return eqBands_; }
    void setPreamp(double db);            // Winamp preamp, -12..+12 dB
    double preamp() const { return preampDb_; }   // dB, not the linear gain
    // Diagnostics: what GStreamer ACTUALLY has on the elements, read back off
    // them, versus what eqBands()/preamp() say was asked for. The two must
    // agree — a setter that stores but never applies is otherwise invisible,
    // and so is a stage that was never found by name.
    std::array<double, 10> eqBandGains() const;   // dB, off band0..band9
    double preampLinearGain() const;              // linear factor; -1 = no stage
    // ...and whether the pipeline itself is running, which paused() only
    // claims: the two drifting apart is silence with the play button lit
    bool pipelinePlaying() const;
    void setBalance(double v);            // -1 left .. 0 centre .. +1 right
    double position() const;              // current-track seconds (or -1)
    double mixerPositionSeconds() const;  // master timeline (diagnostics)
    void setSinkMuted(bool muted);        // remnant-tail mute across hard cuts
    double duration() const;              // current-track seconds (or -1)

    // ---- video: decks are made only while a surface wants them --------------
    void setVideoWanted(bool on);   // false keeps the decks until dropVideoDecksIfUnwanted()
    void dropVideoDecksIfUnwanted();
    QStringList videoCodecs() const { return videoCodecs_; }
    // Decks hand over NV12/I420 by default; false asks videoconvert
    // for RGBA, for a build without the planar material.
    void setVideoPlanar(bool on) { videoPlanar_ = on; }
    // incoming = prerolled for the next track; trackId empty = unknown, binds to whatever plays
    void attachVideo(const QString& url, bool incoming, const QString& trackId);
    void discardPendingVideo();
    void dropVideoDecks();
    bool hasVideoDeck() const;
    void dropFailedVideoDecks();
    double fadeProgress() const { return fadeTimer_.isActive() || fadeFrozen_ ? std::min(fadePos_, 1.0) : 0.0; }
    VideoView videoView() override;
    // What is heard trails the mixer by the audio queue and the sink buffer:
    // frames are picked that much earlier (120 ms on pulsesink).
    double outputLatencySeconds() const;
    // Hidden ui key videoSyncMs; positive shows the picture later.
    void setVideoSyncMs(int ms) { videoSyncMs_ = ms; }
    double videoLeadSeconds() const { return outputLatencySeconds() + videoSyncMs_ / 1000.0; }
    double videoPositionFor(double audioSeconds) const;   // never below 0

signals:
    void positionTick(double seconds, double duration);   // ~4 Hz while playing
    void trackEnded();                                     // current deck hit EOS
    void pipelineError(const QString& message);
    void videoChanged();   // a deck appeared, got its first frame, or went away

private:
    static GstFlowReturn onNewSample(GstAppSink* sink, gpointer user);
    void buildPipeline();
    std::unique_ptr<SourceDeck> makeDeck(const QString& pathOrUri, bool deferLink = false);
    void onFadeTick();

    PcmQueue&   vizQueue_;
    GstElement* pipeline_ = nullptr;
    GstElement* mixer_    = nullptr;
    GstElement* preampEl_ = nullptr;   // volume(preamp), ahead of the bands
    GstElement* eq_       = nullptr;
    GstElement* pan_      = nullptr;   // audiopanorama (balance); null if unavailable
    GstElement* vizVol_   = nullptr;   // viz-branch volume (visualizer parity)
    GstElement* sinkVol_  = nullptr;   // GstStreamVolume sink (audible, instant)
    GstElement* appsink_  = nullptr;

    bool messageIsFromCurrentDeck(GstObject* src) const;

    std::unique_ptr<SourceDeck> current_;
    std::unique_ptr<SourceDeck> incoming_;   // during crossfade
    double pendingIncomingSeek_ = -1;        // silence-skip landed before the deck prerolled
    std::vector<std::unique_ptr<SourceDeck>> retiring_;  // fading out, torn down on fade end

    QTimer posTimer_;
    QTimer fadeTimer_;
    double fadePos_ = 0, fadeStep_ = 0;
    bool fadeFrozen_ = false;   // fade suspended by pause
    bool pipelineErrored_ = false;   // bus ERROR seen; loadTrack must NULL-reset
    bool paused_ = false;
    std::array<double, 10> eqBands_ = {0,0,0,0,0,0,0,0,0,0};
    double preampDb_ = 0.0;     // dB; converted to a linear factor at the element
    double balance_ = 0.0;

    std::unique_ptr<VideoDeck> makeVideoDeck(const QString& url);
    std::unique_ptr<VideoDeck> videoCurrent_;    // bound to current_
    std::unique_ptr<VideoDeck> videoIncoming_;   // bound to incoming_
    std::unique_ptr<VideoDeck> videoPending_;    // prerolled, bound by the next loadTrack/crossfadeTo
    std::shared_ptr<const VideoPixels> lastMainPixels_;   // shown while a re-attached deck has no frame yet
    // The track each audio deck, the pending video deck and the hold belong to (empty: unknown);
    // a video deck binds only to its own track's audio deck.
    QString currentTrack_, incomingTrack_, videoPendingTrack_, lastMainTrack_;
    bool dissolveOutgoing_ = false;   // the outgoing picture may show under the incoming one this fade
    void promoteIncoming();   // the incoming deck and its video become current at a fade's end
    void clearHold() { lastMainPixels_.reset(); lastMainTrack_.clear(); }
    bool videoWanted_ = false;
    bool videoPlanar_ = true;
    QStringList videoCodecs_;
    struct OutputLead { double queue = 0, sink = 0; };   // seconds
    OutputLead outputLeadParts() const;
    void logOutputLeadOnce();
    GstElement* audioQueue_  = nullptr;
    GstElement* audibleSink_ = nullptr;   // pulsesink, fakesink or autoaudiosink
    int videoSyncMs_ = 0;
    bool outputLeadLogged_ = false;
};
