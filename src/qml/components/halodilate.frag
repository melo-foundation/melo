#version 440

// Outline by dilation: max coverage at N points round the ring of one white
// copy of the words, instead of N Text items re-laid-out on every resize.
// Softness adds a full-strength ring at 2/3 radius.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  colourV;   // straight rgb; a is the effect's opacity
    vec2  ringStep;  // the ring's radius, in texture coordinates
    float taps;      // points round the ring, at most 64
    float inner;     // 1: the second ring is on
    float outerA;    // the outer ring's strength when the second is on
    vec2  texSize;   // the texture, in texels: one per device pixel
};

void main() {
    // Sample from a texel centre. At a fractional device scale the fragment's
    // own coordinate falls between texels, and taps a texel or two out then
    // land one texel further on one side than the other, leaning the ring.
    // Snapped, every pair of opposite taps rounds the same way.
    vec2 uv = (floor(qt_TexCoord0 * texSize) + 0.5) / texSize;
    float o = texture(src, uv).a, i = 0.0;
    int n = int(taps);
    for (int k = 0; k < 64; k++) {
        if (k >= n) break;
        float a = 6.2831853 * float(k) / float(n);
        vec2 d = vec2(cos(a), sin(a)) * ringStep;
        o = max(o, texture(src, uv + d).a);
        if (inner > 0.5) i = max(i, texture(src, uv + d * 0.66).a);
    }
    float cover = max(o * outerA, i);
    float al = cover * colourV.a * qt_Opacity;
    fragColor = vec4(colourV.rgb * al, al);
}
