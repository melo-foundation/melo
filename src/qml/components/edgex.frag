#version 440

// Horizontal distance to empty coverage, capped at `reach` texels (32 logical px,
// up to 128; at most 512 texels). Past 32 texels the scan steps two: deep contour
// rings need no per-pixel precision. Outside the item counts as empty;
// clamp-to-edge would erase the bevel where content touches the texture edge.
// Blue: how far in from that empty sample the boundary sits, by coverage. 0.5 for
// a hard edge; on a slanted one it moves smoothly instead of a texel at a time.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float reach;
};
float cover(vec2 p) {
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 0.0;
    return texture(src, p).a;
}
// from the empty sample back to where coverage crosses 0.5, toward the inside one
float inset(float gap, float inside, float empty) {
    // the two-texel steps past 32 keep the plain half texel
    return gap > 1.0 ? 0.5 : clamp((0.5 - empty) / max(inside - empty, 1e-4), 0.0, 1.0);
}
void main() {
    vec2 p = qt_TexCoord0;
    float distance = 0.0, corr = 0.5;
    float c0 = cover(p);
    if (c0 >= 0.5) {
        distance = reach;
        float prev = 0.0, aL = c0, aR = c0;
        for (int i = 1; i <= 272; ++i) {
            float s = float(i) <= 32.0 ? float(i) : 32.0 + (float(i) - 32.0) * 2.0;
            if (s > reach) break;
            vec2 dx = vec2(s / max(size.x, 1.0), 0.0);
            float l = cover(p - dx), r = cover(p + dx);
            if (l < 0.5 || r < 0.5) {
                distance = s;
                corr = 0.0;
                if (l < 0.5) corr = max(corr, inset(s - prev, aL, l));
                if (r < 0.5) corr = max(corr, inset(s - prev, aR, r));
                break;
            }
            prev = s; aL = l; aR = r;
        }
    }
    // High and low bytes survive RGBA8 targets with subpixel precision, and
    // their weighted sum stays linear under texture filtering. Never multiply
    // data by qt_Opacity: fading an entry must not change its edge geometry.
    float packed = distance / reach * 255.0;
    // corr is 0..1 as 0..254 of 255, which holds a hard edge's 0.5 exactly
    fragColor = vec4(floor(packed) / 255.0, fract(packed), corr * 254.0 / 255.0, 1.0);
}
