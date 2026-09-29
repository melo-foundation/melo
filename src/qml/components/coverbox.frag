#version 440

// Coverage as each texel's area: an n x n box of the finer mask, n up to 4. A filtered
// read of a finer mask is not that area; its error repeats at every row crossing of a
// slanted edge, and a bevel's light shows it.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
};
void main() {
    vec2 px = 1.0 / max(size, vec2(1.0));
    int n = clamp(int(floor(float(textureSize(src, 0).x) * px.x + 0.5)), 1, 4);
    float sum = 0.0;
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i)
            sum += textureLod(src, qt_TexCoord0 + ((vec2(float(i), float(j)) + 0.5) / float(n) - 0.5) * px, 0.0).a;
    fragColor = vec4(sum / float(n * n));
}
