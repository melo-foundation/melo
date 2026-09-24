#pragma once
#include <cstdio>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QTimer>
#include <vector>
#include <mutex>
#include <atomic>

// Audio-reactive data for the vis-* backgrounds and 2D visualizers. feed()
// (static, GStreamer thread, same push site as the projectM PcmQueue) taps
// stereo PCM into a mono ring; a ~60fps timer runs a Hann-windowed radix-2 FFT
// and exposes AnalyserNode-compatible byte bins ([-100,-30] dB -> 0..255, 0.8
// smoothing) and a waveform. QML reads bins()/wave() on `updated`.
class SpectrumSource : public QObject {
    Q_OBJECT
public:
    // Frozen during an interactive resize: a plugin visualiser repainting at
    // audio rate in a sibling window makes KWin stretch-fit stale buffers while
    // melo is dragged. PlaybackCoordinator freezes position for the same reason.
    Q_INVOKABLE void setFrozen(bool on) { frozen_ = on; }
    explicit SpectrumSource(QObject* parent = nullptr);
    ~SpectrumSource() override;

    // GStreamer thread. interleaved stereo floats, floatCount total.
    static void feed(const float* interleaved, std::size_t floatCount);

    // 0..255 frequency magnitudes (kBins entries); QVariantList for QML.
    Q_INVOKABLE QVariantList bins() const;
    // time-domain waveform, kWave points in [-1, 1].
    Q_INVOKABLE QVariantList wave() const;
    Q_INVOKABLE int binCount() const { return kBins; }
    // zero-copy access for C++ consumers (BackgroundItem); GUI thread only
    const std::vector<float>& binsRaw() const { return bins_; }
    const std::vector<float>& waveRaw() const { return wave_; }
    Q_INVOKABLE int waveCount() const { return kWave; }

    // Owner set for the FFT: it runs while any owner wants it. One key per writer,
    // holding that writer's latest answer; writes are idempotent.
    //
    // A set, not a refcount: PluginWindowHost::syncSpectrum restates `true` on
    // every show/hide, so a count would never reach zero, and a host's teardown
    // releases twice, which would stop analysis under a live owner.
    //
    // Keys: "background" (shared by both BackgroundLayer.qml instances, which live
    // the whole run and see the same transitions) and one per plugin window host,
    // minted monotonically ("plugin-windows", "plugin-windows#1", ...) and
    // released in its destructor, so a host cannot release another's key
    // (tst_windowsnap asecondHostCannotReleaseTheFirstHostsKey). A plugin can make
    // the shell write only its own key (see MeloUi.h).
    //
    // GUI thread only, no lock. feed() on the GStreamer thread reads only the
    // atomic `active_`; keep the set and its QString lookup off the PCM path.
    //
    // Q_INVOKABLE for melo's BackgroundLayer.qml. `Spectrum` is a context property
    // of the main engine only; plugins get the read-only MeloUiSpectrum.
    Q_INVOKABLE void request(const QString& owner, bool on);
    // Test/diagnostic readers. Not Q_INVOKABLE: nothing in QML needs them.
    bool running() const { return timer_.isActive(); }
    QStringList owners() const { auto l = owners_.values(); l.sort(); return l; }

signals:
    void updated();

private:
    bool frozen_ = false;   // interactive resize in progress
    void analyse();

    static constexpr int kFFT  = 1024;   // window size (power of two)
    static constexpr int kBins = kFFT / 2;
    static constexpr int kWave = 256;

    static SpectrumSource* instance_;
    static std::mutex ringMx_;
    static std::vector<float> ring_;     // mono, kFFT most-recent samples
    static std::size_t ringPos_;
    // What feed() reads on the GStreamer thread: the owner set's emptiness,
    // published as one atomic. Written in exactly two places: request(), which
    // publishes the set, and ~SpectrumSource, which clears it because the set
    // dies with the instance while THIS does not.
    static std::atomic<bool> active_;

    QSet<QString> owners_;               // GUI thread only — see request()
    QTimer timer_;
    std::vector<float> win_;             // Hann window
    std::vector<float> bins_;            // smoothed 0..255
    std::vector<float> wave_;            // -1..1
};
