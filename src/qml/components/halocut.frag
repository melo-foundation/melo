#version 440

// Blur, then cut. A Gaussian-blurred edge reads 0.5 * erfc(d / (sigma * sqrt 2))
// at d outside it, so a cut at 0.159 lands one sigma out: the size asked
// for is the size drawn. `lo`..`hi` is the cut — close together for a hard
// outline, wide for a soft one, the whole falloff for a glow.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  colourV;   // straight rgb; a is the effect's opacity
    float lo;
    float hi;
};

void main() {
    float b = texture(src, qt_TexCoord0).a;
    float a = smoothstep(lo, hi, b) * colourV.a * qt_Opacity;
    fragColor = vec4(colourV.rgb * a, a);
}
