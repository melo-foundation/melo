#include "VideoDeck.h"
#include <gst/video/video.h>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <thread>
#include "../core/LogClock.h"

static std::mutex s_teardownMutex;
static std::condition_variable s_teardownsCv;
static int s_teardownsActive = 0;

// videoconvert's library core, for a renderer that cannot draw planes.
struct VideoDeck::RgbaConverter {
    std::mutex m;
    GstVideoConverter* conv = nullptr;
    GstVideoInfo in{}, out{};
    ~RgbaConverter() { if (conv) gst_video_converter_free(conv); }

    std::shared_ptr<const VideoPixels> convert(const GstVideoFrame* src) {
        std::lock_guard<std::mutex> lk(m);
        if (!conv || !gst_video_info_is_equal(&in, &src->info)) {
            if (conv) gst_video_converter_free(conv);
            in = src->info;
            // the converter refuses an output whose framerate or interlacing differs
            gst_video_info_set_interlaced_format(&out, GST_VIDEO_FORMAT_RGBA, in.interlace_mode,
                                                 in.width, in.height);
            out.fps_n = in.fps_n; out.fps_d = in.fps_d;
            out.par_n = in.par_n; out.par_d = in.par_d;
            conv = gst_video_converter_new(&in, &out, nullptr);
            if (!conv) return nullptr;
        }
        GstBuffer* buf = gst_buffer_new_allocate(nullptr, out.size, nullptr);
        auto* dst = new GstVideoFrame;
        if (!gst_video_frame_map(dst, &out, buf, GST_MAP_READWRITE)) {
            delete dst; gst_buffer_unref(buf); return nullptr;
        }
        gst_video_converter_frame(conv, src, dst);
        auto px = std::make_shared<VideoPixels>();
        px->width = in.width;
        px->height = in.height;
        px->planes[0] = {static_cast<const unsigned char*>(GST_VIDEO_FRAME_PLANE_DATA(dst, 0)),
                         in.width, in.height, int(GST_VIDEO_FRAME_PLANE_STRIDE(dst, 0))};
        px->keepAlive = std::shared_ptr<void>(nullptr, [dst, buf](void*) {
            gst_video_frame_unmap(dst); delete dst; gst_buffer_unref(buf);
        });
        return px;
    }
};

// The caps' colorimetry; without one, HD is BT.709 and SD is BT.601.
static VideoColor colorOf(const GstVideoInfo& info) {
    VideoColor c;
    switch (info.colorimetry.matrix) {
    case GST_VIDEO_COLOR_MATRIX_BT601: c.matrix = VideoMatrix::BT601; break;
    case GST_VIDEO_COLOR_MATRIX_BT2020: c.matrix = VideoMatrix::BT2020; break;
    case GST_VIDEO_COLOR_MATRIX_BT709: c.matrix = VideoMatrix::BT709; break;
    default: c.matrix = info.height > 576 ? VideoMatrix::BT709 : VideoMatrix::BT601; break;
    }
    c.fullRange = info.colorimetry.range == GST_VIDEO_COLOR_RANGE_0_255;
    return c;
}

gpointer VideoDeck::newLiveRef() { return new std::shared_ptr<Liveness>(live_); }
void VideoDeck::releaseLiveRef(gpointer p) { delete static_cast<std::shared_ptr<Liveness>*>(p); }

VideoDeck::VideoDeck(const std::string& uri, Output out) {
    static int n = 0;
    const int id = n++;
    auto nm = [&](const char* base) { return std::string(base) + std::to_string(id); };

    name_ = nm("vdeck");
    pipeline_ = gst_pipeline_new(name_.c_str());
    GstElement* decode = gst_element_factory_make("uridecodebin", nm("vdec").c_str());
    queue_ = gst_element_factory_make("queue", nm("vq").c_str());
    GstElement* convert = gst_element_factory_make("videoconvert", nm("vconv").c_str());
    appsink_ = gst_element_factory_make("appsink", nm("vsink").c_str());
    g_object_set(decode, "uri", uri.c_str(), nullptr);
    // A ring buffer puts qtdemux in pull mode; in push mode it refuses seeks in fragmented MP4.
    g_object_set(decode, "ring-buffer-max-size", guint64(32 * 1024 * 1024), nullptr);
    g_object_set(queue_, "max-size-buffers", 2u, "max-size-bytes", 0u, "max-size-time", guint64(0), nullptr);
    GstCaps* caps = gst_caps_from_string(out == Output::Planar ? "video/x-raw,format={NV12,I420}"
                                                               : "video/x-raw,format=RGBA");
    gst_app_sink_set_caps(GST_APP_SINK(appsink_), caps);
    gst_caps_unref(caps);
    // Nobody pulls in the callbacks: six queued frames block the decoder,
    // which is what keeps a hidden surface from decoding (and downloading) ahead.
    g_object_set(appsink_, "sync", FALSE, "max-buffers", 6u, "drop", FALSE,
                 "emit-signals", FALSE, nullptr);
    GstAppSinkCallbacks cbs{};
    cbs.new_preroll = &VideoDeck::onNewPreroll;
    cbs.new_sample = &VideoDeck::onNewSample;
    gst_app_sink_set_callbacks(GST_APP_SINK(appsink_), &cbs, newLiveRef(), &VideoDeck::releaseLiveRef);

    gst_bin_add_many(GST_BIN(pipeline_), decode, queue_, convert, appsink_, nullptr);
    gst_element_link_many(queue_, convert, appsink_, nullptr);
    g_signal_connect_data(decode, "pad-added", G_CALLBACK(onPadAdded), newLiveRef(),
                          [](gpointer d, GClosure*) { releaseLiveRef(d); }, GConnectFlags(0));
    GstPad* sinkPad = gst_element_get_static_pad(appsink_, "sink");
    gst_pad_add_probe(sinkPad, GST_PAD_PROBE_TYPE_EVENT_FLUSH,
                      &VideoDeck::flushProbe, newLiveRef(), &VideoDeck::releaseLiveRef);
    gst_object_unref(sinkPad);

    // Nobody watches this bus: only errors are kept, for failed().
    bus_ = gst_element_get_bus(pipeline_);
    gst_bus_set_sync_handler(bus_, [](GstBus*, GstMessage* m, gpointer) {
        return GST_MESSAGE_TYPE(m) == GST_MESSAGE_ERROR ? GST_BUS_PASS : GST_BUS_DROP;
    }, nullptr, nullptr);

    // live before PAUSED: the preroll can arrive before the constructor returns
    { std::lock_guard<std::mutex> lk(live_->m); live_->self = this; }
    gst_element_set_state(pipeline_, GST_STATE_PAUSED);
    std::fprintf(stderr, "[%9.1f] [%s] built for %.90s\n", meloLogMs(), name_.c_str(), uri.c_str());
}

VideoDeck::~VideoDeck() {
    { std::lock_guard<std::mutex> lk(live_->m); live_->self = nullptr; }
    GstElement* pipeline = pipeline_;
    GstBus* bus = bus_;
    pipeline_ = nullptr;
    bus_ = nullptr;
    { std::lock_guard<std::mutex> l(s_teardownMutex); ++s_teardownsActive; }
    // NULL-ing waits for the streaming threads; a stuck network read would
    // hold the GUI thread, so it happens on a worker (as SourceDeck does).
    std::thread([pipeline, bus] {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(bus);
        gst_object_unref(pipeline);
        std::lock_guard<std::mutex> l(s_teardownMutex);
        if (--s_teardownsActive == 0) s_teardownsCv.notify_all();
    }).detach();
}

void VideoDeck::joinAllTeardowns() {
    std::unique_lock<std::mutex> l(s_teardownMutex);
    if (!s_teardownsCv.wait_for(l, std::chrono::seconds(5), [] { return s_teardownsActive == 0; }))
        std::fprintf(stderr, "[%9.1f] [vdeck] %d teardown worker(s) still busy at exit\n", meloLogMs(),
                     s_teardownsActive);
}

void VideoDeck::start() {
    {
        std::lock_guard<std::mutex> lk(shownMutex_);
        // the preroll shows on the first tick, not after PLAYING renders it,
        // unless a parked seek means it is the wrong picture
        if (!lastShown_.px && appsink_ && pendingSeek_ < 0)
            if (GstSample* s = gst_app_sink_try_pull_preroll(GST_APP_SINK(appsink_), 0)) lastShown_ = wrap(s);
        started_ = true;
    }
    gst_element_set_state(pipeline_, GST_STATE_PLAYING);
}

// Every queued error is logged, not only the first.
bool VideoDeck::failed() {
    while (GstMessage* m = gst_bus_pop_filtered(bus_, GST_MESSAGE_ERROR)) {
        GError* err = nullptr;
        gchar* dbg = nullptr;
        gst_message_parse_error(m, &err, &dbg);
        std::fprintf(stderr, "[%9.1f] [%s] error from %s: %s | %s\n", meloLogMs(), name_.c_str(),
                     GST_OBJECT_NAME(m->src), err ? err->message : "unknown", dbg ? dbg : "");
        if (err) g_error_free(err);
        g_free(dbg);
        failed_ = true;
        gst_message_unref(m);
    }
    return failed_;
}

void VideoDeck::onFirstFrame(std::function<void()> cb) {
    bool already;
    {
        std::lock_guard<std::mutex> lk(live_->m);
        firstFrameCb_ = cb;
        already = firstFired_.load();
    }
    if (already && cb) cb();
}

void VideoDeck::onSeekLanded(std::function<void()> cb) {
    std::lock_guard<std::mutex> lk(live_->m);
    seekLandedCb_ = std::move(cb);
}

bool VideoDeck::canSeek() const {
    GstState st = GST_STATE_NULL;
    gst_element_get_state(pipeline_, &st, nullptr, 0);
    return st == GST_STATE_PAUSED || st == GST_STATE_PLAYING;
}

void VideoDeck::sendSeek(double seconds) {
    seekTarget_.store(seconds);
    if (!seekInFlight_.exchange(true))
        gst_element_call_async(pipeline_, &VideoDeck::seekWorker, newLiveRef(), &VideoDeck::releaseLiveRef);
}

// Runs on a GStreamer pool thread; touches the deck only under live->m.
void VideoDeck::seekWorker(GstElement* pipeline, gpointer user) {
    auto ref = *static_cast<std::shared_ptr<Liveness>*>(user);
    for (;;) {
        double target;
        {
            std::lock_guard<std::mutex> lk(ref->m);
            if (!ref->self) return;
            target = ref->self->seekTarget_.exchange(-1);
            if (target < 0) {
                ref->self->seekInFlight_.store(false);
                // a target stored after the exchange saw the flag still set
                if (ref->self->seekTarget_.load() < 0 || ref->self->seekInFlight_.exchange(true)) return;
                continue;
            }
        }
        const bool ok = gst_element_seek_simple(pipeline, GST_FORMAT_TIME,
            GstSeekFlags(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE),
            gint64(target * GST_SECOND)) == TRUE;
        if (ok) {
            // the flush is done: the next sample is the new place's
            std::lock_guard<std::mutex> lk(ref->m);
            if (ref->self) ref->self->seekSentMs_.store(meloLogMs());
            continue;
        }
        std::lock_guard<std::mutex> lk(ref->m);
        if (!ref->self) return;
        ref->self->seekRefused_.store(true);
        // no FLUSH_STOP will come: frames from where the deck is are current again
        if (ref->self->seekTarget_.load() < 0)
            ref->self->acceptGen_.store(ref->self->ring_.generation());
        std::fprintf(stderr, "[%9.1f] [%s] seek refused at %.2f\n", meloLogMs(),
                     ref->self->name_.c_str(), target);
    }
}

bool VideoDeck::seekTo(double seconds) {
    std::lock_guard<std::mutex> lk(shownMutex_);
    // A started deck that never showed holds its own preroll through the seek.
    if (!lastShown_.px && appsink_ && started_)
        if (GstSample* s = gst_app_sink_try_pull_preroll(GST_APP_SINK(appsink_), 0)) lastShown_ = wrap(s);
    // frames pulled before FLUSH_STOP keep the old number; the last shown
    // picture holds until the first new one
    ring_.bumpGeneration();
    if (!canSeek()) {
        pendingSeek_ = seconds;   // sent by the next frameAt() once prerolled
        return true;
    }
    pendingSeek_ = -1;
    sendSeek(seconds);
    return true;
}

VideoFrame VideoDeck::wrap(GstSample* sample) {
    VideoFrame f;
    f.gen = acceptGen_.load();
    GstVideoInfo info;
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample))) { gst_sample_unref(sample); return f; }
    auto* vf = new GstVideoFrame;
    if (!gst_video_frame_map(vf, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
        delete vf; gst_sample_unref(sample); return f;
    }
    auto px = std::make_shared<VideoPixels>();
    switch (GST_VIDEO_FRAME_FORMAT(vf)) {
    case GST_VIDEO_FORMAT_NV12: px->format = VideoFormat::NV12; break;
    case GST_VIDEO_FORMAT_I420: px->format = VideoFormat::I420; break;
    case GST_VIDEO_FORMAT_RGBA: px->format = VideoFormat::RGBA; break;
    default:   // the caps allow nothing else
        gst_video_frame_unmap(vf); delete vf; gst_sample_unref(sample); return f;
    }
    px->width = int(GST_VIDEO_FRAME_WIDTH(vf));
    px->height = int(GST_VIDEO_FRAME_HEIGHT(vf));
    px->planeCount = int(GST_VIDEO_FRAME_N_PLANES(vf));
    // plane sizes are GStreamer's (chroma rounds up on odd sizes), never computed here
    // plane p holds component p in RGBA, NV12 and I420, so COMP_WIDTH(p) is the plane's texels
    for (int p = 0; p < px->planeCount; ++p)
        px->planes[p] = {static_cast<const unsigned char*>(GST_VIDEO_FRAME_PLANE_DATA(vf, p)),
                         int(GST_VIDEO_FRAME_COMP_WIDTH(vf, p)), int(GST_VIDEO_FRAME_COMP_HEIGHT(vf, p)),
                         int(GST_VIDEO_FRAME_PLANE_STRIDE(vf, p))};
    px->color = colorOf(info);
    // the mapping and the sample live exactly as long as a frame refers to them
    px->keepAlive = std::shared_ptr<void>(nullptr, [vf, sample](void*) {
        gst_video_frame_unmap(vf); delete vf; gst_sample_unref(sample);
    });
    if (px->format != VideoFormat::RGBA) {
        if (!rgba_) rgba_ = std::make_shared<RgbaConverter>();
        // `keep` pins the mapping the closure reads, so a twin can be made after the deck is gone
        px->makeRgba = [conv = rgba_, vf, keep = px->keepAlive] { (void)keep; return conv->convert(vf); };
    }
    const GstClockTime pts = GST_BUFFER_PTS(gst_sample_get_buffer(sample));
    f.pts = GST_CLOCK_TIME_IS_VALID(pts) ? double(pts) / GST_SECOND : 0.0;
    px->pts = f.pts;
    f.px = px;
    return f;
}

void VideoDeck::pullInto(double limit) {
    if (!appsink_) return;
    for (;;) {
        const auto newest = ring_.newestPts();
        if (newest && *newest > limit) return;
        GstSample* s = started_ ? gst_app_sink_try_pull_sample(GST_APP_SINK(appsink_), 0)
                                : gst_app_sink_try_pull_preroll(GST_APP_SINK(appsink_), 0);
        if (!s) return;
        VideoFrame f = wrap(s);
        if (f.px) ring_.push(std::move(f));
        if (!started_) return;        // the preroll is one frame, until start()
    }
}

std::optional<VideoFrame> VideoDeck::frameAt(double position) {
    std::unique_lock<std::mutex> lk(shownMutex_);
    if (pendingSeek_ >= 0) {
        if (!canSeek()) return std::nullopt;   // the pre-seek preroll must not show
        sendSeek(pendingSeek_);
        pendingSeek_ = -1;
    }
    pullInto(position + 0.02);
    if (auto f = ring_.take(position)) lastShown_ = *f;
    if (!lastShown_.px) return std::nullopt;
    // Over 0.5 s behind the audio, jump (at most once a second) rather than drain
    // the queue at several times real speed; a seek in flight is not behind, and
    // nor is a video past its last frame (a still tail, or shorter than the audio).
    if (lastShown_.gen == ring_.generation() && !gst_app_sink_is_eos(GST_APP_SINK(appsink_))) {
        const double newest = ring_.newestPts().value_or(lastShown_.pts);
        const gint64 now = g_get_monotonic_time();
        if (position - newest > 0.5 && now - lastCatchUpUs_ >= G_USEC_PER_SEC && !seekRefused_.load()) {
            lastCatchUpUs_ = now;
            std::fprintf(stderr, "[%9.1f] [%s] %.2f s behind, jumping to %.2f\n", meloLogMs(), name_.c_str(),
                         position - newest, position);
            const VideoFrame held = lastShown_;
            lk.unlock();
            seekTo(position);
            return held;
        }
    }
    return lastShown_;
}

void VideoDeck::markArrival() {
    sawSample_.store(true);
    if (const double sent = seekSentMs_.exchange(0); sent > 0) {
        std::fprintf(stderr, "[%9.1f] [%s] seek landed in %.0f ms\n", meloLogMs(), name_.c_str(),
                     meloLogMs() - sent);
        if (seekLandedCb_) seekLandedCb_();
    }
    if (!firstFired_.exchange(true) && firstFrameCb_) firstFrameCb_();
}

GstFlowReturn VideoDeck::onNewPreroll(GstAppSink*, gpointer user) {
    auto ref = *static_cast<std::shared_ptr<Liveness>*>(user);
    std::lock_guard<std::mutex> lk(ref->m);
    if (ref->self) ref->self->markArrival();
    return GST_FLOW_OK;
}

GstFlowReturn VideoDeck::onNewSample(GstAppSink*, gpointer user) {
    auto ref = *static_cast<std::shared_ptr<Liveness>*>(user);
    std::lock_guard<std::mutex> lk(ref->m);
    if (ref->self) ref->self->markArrival();
    return GST_FLOW_OK;
}

void VideoDeck::onPadAdded(GstElement*, GstPad* pad, gpointer user) {
    auto ref = *static_cast<std::shared_ptr<Liveness>*>(user);
    std::lock_guard<std::mutex> lk(ref->m);
    VideoDeck* self = ref->self;
    if (!self) return;
    GstCaps* caps = gst_pad_get_current_caps(pad);
    const bool isVideo = caps && g_str_has_prefix(
        gst_structure_get_name(gst_caps_get_structure(caps, 0)), "video/");
    if (caps) gst_caps_unref(caps);
    if (!isVideo) return;
    GstPad* sink = gst_element_get_static_pad(self->queue_, "sink");
    if (!gst_pad_is_linked(sink)) gst_pad_link(pad, sink);
    gst_object_unref(sink);
}

GstPadProbeReturn VideoDeck::flushProbe(GstPad*, GstPadProbeInfo* info, gpointer user) {
    if (GST_EVENT_TYPE(GST_PAD_PROBE_INFO_EVENT(info)) != GST_EVENT_FLUSH_STOP) return GST_PAD_PROBE_OK;
    auto ref = *static_cast<std::shared_ptr<Liveness>*>(user);
    std::lock_guard<std::mutex> lk(ref->m);
    if (ref->self) ref->self->acceptGen_.store(ref->self->ring_.generation());
    return GST_PAD_PROBE_OK;
}
