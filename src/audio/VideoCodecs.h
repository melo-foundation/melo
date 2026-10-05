#pragma once
#include <QStringList>
#include <functional>

// Hardware first, then AV1 (dav1d is the cheapest software decode), VP9, H.264.
inline QStringList videoCodecPreference(const std::function<bool(const char*)>& hasFactory) {
    static const struct { const char* factory; const char* codec; } table[] = {
        {"vaav1dec", "av1"}, {"vavp9dec", "vp9"}, {"vah264dec", "h264"},
        {"dav1ddec", "av1"}, {"av1dec", "av1"},
        {"vp9dec", "vp9"},
        {"avdec_h264", "h264"}, {"openh264dec", "h264"},
    };
    QStringList out;
    for (const auto& e : table)
        if (hasFactory(e.factory) && !out.contains(QLatin1String(e.codec)))
            out << QLatin1String(e.codec);
    return out;
}
