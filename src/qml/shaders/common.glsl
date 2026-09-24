// Shared preamble for the background shaders (concatenated by build-shaders.sh).
// mulberry32 with the SAME fixed seed as src/vis/BackgroundItem.cpp — GPU and
// CPU renderers generate identical layouts.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

uint _s;
float rnd() {
    _s += 0x6D2B79F5u;
    uint t = _s;
    t = (t ^ (t >> 15)) * (t | 1u);
    t ^= t + ((t ^ (t >> 7)) * (t | 61u));
    return float(t ^ (t >> 14)) / 4294967296.0;
}
void seed() { _s = 0x1a2b3c4du; }

float wrapM(float v) {
    float sp = 1.4;
    v = mod(v + 0.2, sp);
    if (v < 0.0) v += sp;
    return v - 0.2;
}

vec4 colorAt(int i) {
    int m = i % nColors;
    if (m == 0) return c0; if (m == 1) return c1; if (m == 2) return c2;
    if (m == 3) return c3; if (m == 4) return c4; if (m == 5) return c5;
    if (m == 6) return c6; return c7;
}
