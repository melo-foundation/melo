#version 440

// Combine each row's nearest empty pixel with its vertical offset. This is
// Euclidean distance, not a blurred alpha: inset rings stay equidistant from
// straight edges, curves, concave corners and holes alike.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float reach;
};
float horizontal(vec2 p) {
    if (p.y < 0.0 || p.y > 1.0) return 0.0;
    vec2 packed = texture(src, p).rg;
    return (packed.r + packed.g / 255.0) * reach;
}
void main() {
    vec2 p = qt_TexCoord0;
    float d = horizontal(p);
    float best = d * d;
    for (int i = 1; i <= 80; ++i) {
        float y = float(i) <= 32.0 ? float(i) : 32.0 + (float(i) - 32.0) * 2.0;
        if (y > reach || y * y >= best) break;
        vec2 dy = vec2(0.0, y / max(size.y, 1.0));
        float a = horizontal(p - dy), b = horizontal(p + dy);
        best = min(best, min(a * a, b * b) + y * y);
    }
    // Empty samples are pixel centres; the visible boundary is halfway to
    // them. Saturated interiors stop at `reach`; the materials fade
    // before that limit rather than drawing a spurious ring at the plateau.
    float packed = min(max(sqrt(best) - 0.5, 0.0), reach) / reach * 255.0;
    fragColor = vec4(floor(packed) / 255.0, fract(packed), 0.0, 1.0);
}
