#version 440

// Horizontal distance to empty coverage, capped at `reach` logical px (32, up
// to 128). Past 32 the scan steps two texels: deep contour rings need no
// per-pixel precision. Outside the item counts as empty; clamp-to-edge would
// erase the bevel where content touches the texture edge.
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
void main() {
    vec2 p = qt_TexCoord0;
    float distance = 0.0;
    if (cover(p) >= 0.5) {
        distance = reach;
        for (int i = 1; i <= 80; ++i) {
            float s = float(i) <= 32.0 ? float(i) : 32.0 + (float(i) - 32.0) * 2.0;
            if (s > reach) break;
            vec2 dx = vec2(s / max(size.x, 1.0), 0.0);
            if (cover(p - dx) < 0.5 || cover(p + dx) < 0.5) { distance = s; break; }
        }
    }
    // High and low bytes survive RGBA8 targets with subpixel precision, and
    // their weighted sum stays linear under texture filtering. Never multiply
    // data by qt_Opacity: fading an entry must not change its edge geometry.
    float packed = distance / reach * 255.0;
    fragColor = vec4(floor(packed) / 255.0, fract(packed), 0.0, 1.0);
}
