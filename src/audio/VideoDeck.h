#pragma once
#include "VideoFrameRing.h"
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

// One track's picture: uridecodebin ! queue ! videoconvert ! appsink, in its
// own pipeline so its preroll, seeks and errors never touch audio. The appsink
// takes the decoder's own NV12 or I420 (videoconvert is a passthrough then,
// 0.08 ms a frame) or RGBA for a build without the planar material.
// The appsink queue is the pacing buffer: six frames, then the decoder waits
// until frameAt() pulls. Frames are picked by the audio deck's position
// (VideoFrameRing), so this deck has no clock.
class VideoDeck {
public:
    enum class Output { Rgba, Planar };
    explicit VideoDeck(const std::string& uri, Output out = Output::Planar);
    ~VideoDeck();

    void start();
    bool seekTo(double seconds);
    std::optional<VideoFrame> frameAt(double position);
    bool hasFrame() const { return sawSample_.load(); }
    void onFirstFrame(std::function<void()> cb);   // runs now if the first frame already came
    bool failed();                                 // sticky once the pipeline posts an error
    uint64_t generation() const { return ring_.generation(); }

    static void joinAllTeardowns();

private:
    struct Liveness { std::mutex m; VideoDeck* self = nullptr; };
    static GstFlowReturn onNewSample(GstAppSink* sink, gpointer user);
    static GstFlowReturn onNewPreroll(GstAppSink* sink, gpointer user);
    static void onPadAdded(GstElement* decode, GstPad* pad, gpointer user);
    static GstPadProbeReturn flushProbe(GstPad* pad, GstPadProbeInfo* info, gpointer user);
    static void seekWorker(GstElement* pipeline, gpointer user);
    gpointer newLiveRef();
    static void releaseLiveRef(gpointer p);
    void markArrival();
    VideoFrame wrap(GstSample* sample);
    struct RgbaConverter;
    std::shared_ptr<RgbaConverter> rgba_;   // RGBA twins of planar frames; shared with the frames' closures
    void pullInto(double limit);     // pull from the appsink until a frame is past `limit`
    bool canSeek() const;          // PAUSED or PLAYING: GStreamer drops a seek sent before preroll
    void sendSeek(double seconds);   // a pull-mode seek may read over HTTP, so it runs on a worker

    GstElement* pipeline_ = nullptr;
    GstBus* bus_ = nullptr;
    GstElement* queue_ = nullptr;
    GstElement* appsink_ = nullptr;
    std::shared_ptr<Liveness> live_ = std::make_shared<Liveness>();
    VideoFrameRing ring_{8};
    std::atomic<uint64_t> acceptGen_{0};   // frames pulled now belong to this generation
    std::atomic<double> seekTarget_{-1};   // the latest unsent seek; -1 when none
    std::atomic<bool> seekInFlight_{false};
    std::atomic<bool> seekRefused_{false}; // no more catch-up seeks once one is refused
    std::atomic<bool> sawSample_{false};
    std::atomic<bool> firstFired_{false};
    std::function<void()> firstFrameCb_;
    bool started_ = false;
    bool failed_ = false;
    VideoFrame lastShown_;
    double pendingSeek_ = -1;   // parked until the pipeline can seek; under shownMutex_
    gint64 lastCatchUpUs_ = 0;  // monotonic time of the last catch-up seek; under shownMutex_
    std::mutex shownMutex_;
};
