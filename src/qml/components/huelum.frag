#version 440

// Hue and luminosity as continuous amounts over the backdrop. BlendRect's
// hardware blend factors act per channel; separating hue from lightness needs
// max/min across r, g, b, hence a texture. So the backdrop must be something
// melo drew: the compositor's desktop is out of reach (over it, wl_region
// contrast and saturation are the only knobs).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source;   // what is behind
layout(binding = 2) uniform sampler2D mask;     // coverage: white glyphs

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float hue;   // -1..1, a full turn of the colour wheel at the ends
    float lum;   // -1..1, see below
    float sat;   // -1..1, -1 grey, 0 unchanged, 1 doubled
    float hasMask;  // 0 fills the whole item, 1 fills glyph coverage
    // where this item sits in `source`, normalised: (x, y, w, h). The ground
    // is ONE texture read by every adaptive surface, and this is how each one
    // reads only the part beneath it. (0,0,1,1) when the source is the item's
    // own rect already.
    vec4  srcRect;
};

// HSL both ways, so lightness can be moved while hue and saturation stay
// put. Mixing toward black or white would throw the colour away: over a cyan
// sky, "flip" would land on near-black cyan, which is black. A blue picture
// gives dark blue or light blue words.
vec3 rgb2hsl(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float l = (mx + mn) * 0.5, d = mx - mn;
    if (d < 1e-5) return vec3(0.0, 0.0, l);
    float s = l < 0.5 ? d / (mx + mn) : d / (2.0 - mx - mn);
    float h;
    if (mx == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
    else                h = (c.r - c.g) / d + 4.0;
    return vec3(h / 6.0, s, l);
}
float hue2rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}
vec3 hsl2rgb(vec3 c) {
    if (c.y < 1e-5) return vec3(c.z);
    float q = c.z < 0.5 ? c.z * (1.0 + c.y) : c.z + c.y - c.z * c.y;
    float p = 2.0 * c.z - q;
    return vec3(hue2rgb(p, q, c.x + 1.0 / 3.0), hue2rgb(p, q, c.x), hue2rgb(p, q, c.x - 1.0 / 3.0));
}

// Rotation about the grey axis (Rodrigues). Keeps luminance roughly put,
// which is the point of having a separate lever for it.
vec3 hueRotate(vec3 c, float a) {
    const vec3 k = vec3(0.57735027);
    float ca = cos(a), sa = sin(a);
    return c * ca + cross(k, c) * sa + k * dot(k, c) * (1.0 - ca);
}

void main() {
    vec4 b = texture(source, srcRect.xy + qt_TexCoord0 * srcRect.zw);
    float cover = hasMask > 0.5 ? texture(mask, qt_TexCoord0).a : 1.0;

    // straight alpha to do maths in; the scene graph hands over premultiplied
    vec3 c = b.a > 0.001 ? b.rgb / b.a : b.rgb;

    c = hueRotate(c, hue * 3.14159265);

    vec3 hsl = rgb2hsl(clamp(c, 0.0, 1.0));
    hsl.y = clamp(hsl.y * (1.0 + sat), 0.0, 1.0);

    // Negative inverts, positive flips. Inversion is symmetric about 0.5, so
    // mid-grey text vanishes on mid-grey; the flip keeps separation at the middle.
    // Lightness only; hue and saturation are kept.
    float L = hsl.z;
    float flip = L > 0.5 ? (1.0 - L) * (1.0 - L) : 1.0 - L * L;
    hsl.z = lum < 0.0 ? mix(L, 1.0 - L, -lum) : mix(L, flip, lum);
    c = hsl2rgb(hsl);

    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0) * cover * qt_Opacity;
}
