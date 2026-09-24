#include "SpectrumSource.h"
#include <cmath>
#include <algorithm>

SpectrumSource* SpectrumSource::instance_ = nullptr;
std::mutex SpectrumSource::ringMx_;
std::vector<float> SpectrumSource::ring_(kFFT, 0.0f);
std::size_t SpectrumSource::ringPos_ = 0;
std::atomic<bool> SpectrumSource::active_{false};

SpectrumSource::SpectrumSource(QObject* parent) : QObject(parent) {
    instance_ = this;
    win_.resize(kFFT);
    for (int i = 0; i < kFFT; ++i)                       // Hann window
        win_[i] = 0.5f * (1.0f - std::cos(2.0 * M_PI * i / (kFFT - 1)));
    bins_.assign(kBins, 0.0f);
    wave_.assign(kWave, 0.0f);
    timer_.setInterval(16);   // ~60fps
    connect(&timer_, &QTimer::timeout, this, &SpectrumSource::analyse);
}

// Clear `active_` on destruction: it is static and feed() reads it on the
// GStreamer thread, which would keep copying PCM into a ring nobody analyses
// (tst_spectrumarbiter samplesFedWithNoOwnerNeverReachTheRing). Only the
// current instance_ clears it; an older instance does not own the statics.
SpectrumSource::~SpectrumSource() {
    owners_.clear();
    if (instance_ != this) return;
    instance_ = nullptr;
    active_.store(false);
}

void SpectrumSource::feed(const float* interleaved, std::size_t floatCount) {
    if (!active_.load()) return;
    std::lock_guard<std::mutex> lk(ringMx_);
    // interleaved stereo -> mono average
    for (std::size_t i = 0; i + 1 < floatCount; i += 2) {
        ring_[ringPos_] = 0.5f * (interleaved[i] + interleaved[i + 1]);
        ringPos_ = (ringPos_ + 1) % kFFT;
    }
}

// The arbiter. See the header for the ownership rule and why this is a set
// rather than a refcount.
void SpectrumSource::request(const QString& owner, bool on) {
    // An unnamed owner is refused on BOTH sides, so it can neither start the
    // FFT nor be the thing that fails to release it. A caller with no key is a
    // caller that cannot be arbitrated between.
    if (owner.isEmpty()) return;
    if (on) owners_.insert(owner);
    else    owners_.remove(owner);

    const bool want = !owners_.isEmpty();
    active_.store(want);
    if (want && !timer_.isActive()) timer_.start();
    else if (!want && timer_.isActive()) timer_.stop();
}

// in-place iterative radix-2 Cooley-Tukey FFT (real input -> re/im arrays)
static void fft(std::vector<float>& re, std::vector<float>& im) {
    const int n = (int)re.size();
    for (int i = 1, j = 0; i < n; ++i) {                 // bit-reversal
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const double ang = -2.0 * M_PI / len;
        const float wr = std::cos(ang), wi = std::sin(ang);
        for (int i = 0; i < n; i += len) {
            float cr = 1, ci = 0;
            for (int k = 0; k < len / 2; ++k) {
                const int a = i + k, b = i + k + len / 2;
                const float tr = re[b] * cr - im[b] * ci;
                const float ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr;        im[a] += ti;
                const float ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr; cr = ncr;
            }
        }
    }
}

void SpectrumSource::analyse() {
    std::vector<float> re(kFFT), im(kFFT, 0.0f);
    {
        std::lock_guard<std::mutex> lk(ringMx_);
        // unwrap the ring so the newest sample is last
        for (int i = 0; i < kFFT; ++i)
            re[i] = ring_[(ringPos_ + i) % kFFT];
    }
    // time-domain waveform (downsampled) before windowing
    for (int i = 0; i < kWave; ++i)
        wave_[i] = std::max(-1.0f, std::min(1.0f, re[(int)((long long)i * kFFT / kWave)]));

    for (int i = 0; i < kFFT; ++i) re[i] *= win_[i];     // Hann
    fft(re, im);

    const float smoothing = 0.8f;
    for (int i = 0; i < kBins; ++i) {
        const float mag = std::sqrt(re[i] * re[i] + im[i] * im[i]) / kFFT;
        float db = mag > 1e-9f ? 20.0f * std::log10(mag) : -100.0f;   // dBFS-ish
        float v = (db + 100.0f) / 70.0f;                 // [-100,-30] -> [0,1]
        v = std::max(0.0f, std::min(1.0f, v)) * 255.0f;
        bins_[i] = smoothing * bins_[i] + (1.0f - smoothing) * v;   // AnalyserNode smoothing
    }
    if (!frozen_) emit updated();
}

QVariantList SpectrumSource::bins() const {
    QVariantList out;
    out.reserve(kBins);
    for (float b : bins_) out.append((int)(b + 0.5f));
    return out;
}
QVariantList SpectrumSource::wave() const {
    QVariantList out;
    out.reserve(kWave);
    for (float w : wave_) out.append(w);
    return out;
}
