#pragma once
#include "VideoFrame.h"
#include <array>

// Row-major YUV→RGB for a frame's matrix and range, from Kr/Kb (BT.601
// 0.299/0.114, BT.709 0.2126/0.0722, BT.2020 0.2627/0.0593). Limited range
// scales Y by 255/219 and chroma by 255/224 from 16 and 128. Input is (Y, Cb, Cr, 1).
inline std::array<float, 16> videoColorMatrix(VideoColor c) {
    double kr = 0.2126, kb = 0.0722;
    if (c.matrix == VideoMatrix::BT601) { kr = 0.299; kb = 0.114; }
    if (c.matrix == VideoMatrix::BT2020) { kr = 0.2627; kb = 0.0593; }
    const double kg = 1 - kr - kb;
    const double sy = c.fullRange ? 1.0 : 255.0 / 219.0;
    const double sc = c.fullRange ? 1.0 : 255.0 / 224.0;
    const double oy = c.fullRange ? 0.0 : 16.0 / 255.0;
    const double oc = 128.0 / 255.0;
    const double cr = 2 * (1 - kr) * sc, cb = 2 * (1 - kb) * sc;
    const double gb = 2 * (1 - kb) * kb / kg * sc, gr = 2 * (1 - kr) * kr / kg * sc;
    return {
        float(sy), 0.f,        float(cr),  float(-(sy * oy + cr * oc)),
        float(sy), float(-gb), float(-gr), float(-(sy * oy) + (gb + gr) * oc),
        float(sy), float(cb),  0.f,        float(-(sy * oy + cb * oc)),
        0.f,       0.f,        0.f,        1.f,
    };
}
