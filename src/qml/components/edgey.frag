#version 440

// Combine each row's nearest empty pixel with its vertical offset. This is
// Euclidean distance, not a blurred alpha: inset rings stay equidistant from
// straight edges, curves, concave corners and holes alike.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(binding = 2) uniform sampler2D mask;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float reach;
};
// x: the row's distance to its nearest empty pixel, y: the boundary's inset from it
vec2 horizontal(vec2 p) {
    if (p.y < 0.0 || p.y > 1.0) return vec2(0.0, 0.5);
    vec3 packed = texture(src, p).rgb;
    return vec2((packed.r + packed.g / 255.0) * reach, packed.b * 255.0 / 254.0);
}
float cover(vec2 p) {
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 0.0;
    return texture(mask, p).a;
}
float inset(float gap, float inside, float empty) {
    // the two-texel steps past 32 keep the plain half texel
    return gap > 1.0 ? 0.5 : clamp((0.5 - empty) / max(inside - empty, 1e-4), 0.0, 1.0);
}
void main() {
    vec2 p = qt_TexCoord0;
    vec2 h = horizontal(p);
    float best = h.x * h.x, corr = h.y;
    float prevY = 0.0, step = 1.0 / max(size.y, 1.0);
    for (int i = 1; i <= 272 && best > 0.0; ++i) {
        float y = float(i) <= 32.0 ? float(i) : 32.0 + (float(i) - 32.0) * 2.0;
        if (y > reach || y * y >= best) break;
        for (int side = 0; side < 2; ++side) {
            float sgn = side == 0 ? -1.0 : 1.0;
            vec2 q = p + vec2(0.0, sgn * y * step);
            vec2 r = horizontal(q);
            // an empty row at this column: the boundary is between it and the row before
            float c = r.x > 0.0 ? r.y
                    : inset(y - prevY, cover(p + vec2(0.0, sgn * prevY * step)), cover(q));
            float d = r.x * r.x + y * y;
            if (d < best) { best = d; corr = c; }
        }
        prevY = y;
    }
    // Empty samples are pixel centres; the visible boundary is `corr` in from
    // them, half a texel for a hard edge. Saturated interiors stop at `reach`;
    // the materials fade before that limit rather than drawing a spurious ring.
    float packed = min(max(sqrt(best) - corr, 0.0), reach) / reach * 255.0;
    fragColor = vec4(floor(packed) / 255.0, fract(packed), 0.0, 1.0);
}
