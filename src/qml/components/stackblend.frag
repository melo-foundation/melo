#version 440

// One stack layer over the layers under it, blended in the shader. BlendRect's
// seven modes are fixed-function blend factors that never read the destination;
// overlay, soft-light and the hue family need it. Inside a stack the layers below
// are available as a texture, so this does W3C compositing-and-blending: separable
// modes per channel, the four non-separable ones via luminosity and saturation.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D belowTex;
layout(binding = 2) uniform sampler2D aboveTex;
layout(binding = 3) uniform sampler2D mask;       // the shape's coverage, for a filter's mask mode
layout(binding = 4) uniform sampler2D shapeMap;   // and its distance field
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  par;      // x: mode, y: 1 when there is a backdrop, z: the layer's opacity, w: FILTER kind (0: none)
    vec4  msk;      // a filter's mask: mode (0 all, 1 edge, 2 core), band in px, phase, spare
    vec4  geo;      // the item's size in px, hasMask, spare
    vec4  par2;     // a filter's own options, four floats it names itself
    vec4  par3;     // and four more
};

// Filters are rungs with no fill: they modify the layers below (belowTex), like
// an adjustment layer or backdrop-filter. On the bottom layer they draw nothing.
float lumOf(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 hueRotate(vec3 c, float a) {
    const vec3 k = vec3(0.57735);
    float cs = cos(a), sn = sin(a);
    return c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs);
}
// 8x8 Bayer matrix by arithmetic: qsb's GLSL 1.20 target has no integer xor,
// and a compile failure there breaks every filter. M(2n) = 4·M(n) of the fine
// cell + M(2) of the coarse one, with M(2) = 2*((x + y) mod 2) + y. Threshold is
// centred, (i + 0.5) / 64, so a flat tone keeps its average.
float bayer2(float x, float y) { return 2.0 * mod(x + y, 2.0) + y; }
float bayer4(float x, float y) { return 4.0 * bayer2(mod(x, 2.0), mod(y, 2.0)) + bayer2(floor(x / 2.0), floor(y / 2.0)); }
float bayer8(vec2 p) {
    float x = mod(floor(p.x), 8.0), y = mod(floor(p.y), 8.0);
    return (4.0 * bayer4(mod(x, 4.0), mod(y, 4.0)) + bayer2(floor(x / 4.0), floor(y / 4.0)) + 0.5) / 64.0;
}
// the same distance as styled.frag's, so a filter bands where a fill would
float edgeDistance(vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 0.0;
    float reach = msk.w > 0.0 ? msk.w : 32.0;
    if (geo.z > 0.5) {
        vec2 packed = texture(shapeMap, uv).rg;
        return (packed.r + packed.g / 255.0) * reach;
    }
    vec2 d = min(uv, vec2(1.0) - uv) * geo.xy;
    return min(min(d.x, d.y), reach - 0.5);
}
vec4 filtered(int f, vec2 uv) {
    vec4 d = texture(belowTex, uv);
    vec3 c = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
    if (f == 1) {                                     // pixelate: one sample per cell
        vec2 cell = max(vec2(par2.x), vec2(1.0)) / max(geo.xy, vec2(1.0));
        vec2 q = (floor(uv / cell) + 0.5) * cell;
        d = texture(belowTex, q);
        return d;
    }
    if (f == 2) {                                     // posterize: n levels a channel
        float n = max(par2.x, 2.0) - 1.0;
        c = floor(c * n + 0.5) / n;
    } else if (f == 3) {                              // threshold: black or white about a level
        c = vec3(lumOf(c) < par2.x ? 0.0 : 1.0);
    } else if (f == 4) {                              // invert
        c = 1.0 - c;
    } else if (f == 5) {                              // greyscale
        c = vec3(lumOf(c));
    } else if (f == 6) {                              // sepia
        c = vec3(dot(c, vec3(0.393, 0.769, 0.189)), dot(c, vec3(0.349, 0.686, 0.168)),
                 dot(c, vec3(0.272, 0.534, 0.131)));
    } else if (f == 7) {                              // hue shift, degrees
        c = hueRotate(c, radians(par2.x));
    } else if (f == 8) {                              // contrast about mid grey
        c = (c - 0.5) * par2.x + 0.5;
    } else if (f == 9) {                              // saturate: away from its own grey
        c = mix(vec3(lumOf(c)), c, par2.x);
    } else if (f == 10) {                             // ordered dither to n levels, a channel each
        vec2 px = uv * geo.xy / max(par2.x, 1.0);
        float n = max(par2.y, 2.0) - 1.0, t = (bayer8(px) - 0.5) * par2.z / n;
        c = floor((c + t) * n + 0.5) / n;
    } else if (f == 11) {                             // scanlines: every other band of `pitch` rows, darkened
        float pitch = max(par2.x, 2.0);
        float row = mod(uv.y * geo.y + msk.z * pitch, pitch);
        c *= 1.0 - par2.y * step(pitch * 0.5, row);
    }
    return vec4(clamp(c, 0.0, 1.0) * d.a, d.a);
}

// --- separable, per channel ------------------------------------------------
float bMultiply(float b, float s)   { return b * s; }
float bScreen(float b, float s)     { return b + s - b * s; }
float bHardLight(float b, float s)  { return s <= 0.5 ? bMultiply(b, 2.0 * s)
                                                      : bScreen(b, 2.0 * s - 1.0); }
float bOverlay(float b, float s)    { return bHardLight(s, b); }
float bDodge(float b, float s)      { return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); }
float bBurn(float b, float s)       { return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); }
float bSoftLight(float b, float s) {
    float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
    return s <= 0.5 ? b - (1.0 - 2.0 * s) * b * (1.0 - b)
                    : b + (2.0 * s - 1.0) * (d - b);
}
float bDifference(float b, float s) { return abs(b - s); }
float bExclusion(float b, float s)  { return b + s - 2.0 * b * s; }
// --- the ones past the W3C set, from Krita and GIMP: still one line each ---
float bLinearBurn(float b, float s)  { return clamp(b + s - 1.0, 0.0, 1.0); }
float bLinearDodge(float b, float s) { return min(1.0, b + s); }
float bLinearLight(float b, float s) { return clamp(b + 2.0 * s - 1.0, 0.0, 1.0); }
float bVividLight(float b, float s)  { return s < 0.5 ? bBurn(b, 2.0 * s) : bDodge(b, 2.0 * s - 1.0); }
float bPinLight(float b, float s)    { return s < 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0); }
float bHardMix(float b, float s)     { return bVividLight(b, s) < 0.5 ? 0.0 : 1.0; }
float bDivide(float b, float s)      { return s <= 0.0 ? 1.0 : min(1.0, b / s); }
float bGrainExtract(float b, float s){ return clamp(b - s + 0.5, 0.0, 1.0); }
float bGrainMerge(float b, float s)  { return clamp(b + s - 0.5, 0.0, 1.0); }
float bGeoMean(float b, float s)     { return sqrt(max(b * s, 0.0)); }
float bNegation(float b, float s)    { return 1.0 - abs(1.0 - b - s); }
float bReflect(float b, float s)     { return s >= 1.0 ? 1.0 : min(1.0, b * b / (1.0 - s)); }
float bGlow(float b, float s)        { return b >= 1.0 ? 1.0 : min(1.0, s * s / (1.0 - b)); }
float bAllanon(float b, float s)     { return (b + s) * 0.5; }
#define EACH(F) vec3(F(b.r, s.r), F(b.g, s.g), F(b.b, s.b))

vec3 perChannel(int m, vec3 b, vec3 s) {
    if (m == 1)  return vec3(bMultiply(b.r, s.r), bMultiply(b.g, s.g), bMultiply(b.b, s.b));
    if (m == 2)  return vec3(bScreen(b.r, s.r), bScreen(b.g, s.g), bScreen(b.b, s.b));
    if (m == 3)  return min(b, s);                      // darken
    if (m == 4)  return max(b, s);                      // lighten
    if (m == 5)  return clamp(b - s, 0.0, 1.0);         // subtract, melo's own
    if (m == 6)  return vec3(bOverlay(b.r, s.r), bOverlay(b.g, s.g), bOverlay(b.b, s.b));
    if (m == 7)  return vec3(bDodge(b.r, s.r), bDodge(b.g, s.g), bDodge(b.b, s.b));
    if (m == 8)  return vec3(bBurn(b.r, s.r), bBurn(b.g, s.g), bBurn(b.b, s.b));
    if (m == 9)  return vec3(bHardLight(b.r, s.r), bHardLight(b.g, s.g), bHardLight(b.b, s.b));
    if (m == 10) return vec3(bSoftLight(b.r, s.r), bSoftLight(b.g, s.g), bSoftLight(b.b, s.b));
    if (m == 11) return vec3(bDifference(b.r, s.r), bDifference(b.g, s.g), bDifference(b.b, s.b));
    if (m == 12) return vec3(bExclusion(b.r, s.r), bExclusion(b.g, s.g), bExclusion(b.b, s.b));
    // 13-16 are the non-separable four, handled in main
    if (m == 17) return EACH(bLinearBurn);
    if (m == 18) return EACH(bLinearDodge);
    if (m == 19) return EACH(bLinearLight);
    if (m == 20) return EACH(bVividLight);
    if (m == 21) return EACH(bPinLight);
    if (m == 22) return EACH(bHardMix);
    if (m == 23) return EACH(bDivide);
    if (m == 24) return EACH(bGrainExtract);
    if (m == 25) return EACH(bGrainMerge);
    if (m == 26) return EACH(bGeoMean);
    if (m == 27) return EACH(bNegation);
    if (m == 28) return EACH(bReflect);
    if (m == 29) return EACH(bGlow);
    if (m == 30) return EACH(bAllanon);
    return s;                                           // normal
}

// --- non-separable: the four that move a whole colour, not three channels ---
float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 clipColour(vec3 c) {
    float l = lum(c), lo = min(min(c.r, c.g), c.b), hi = max(max(c.r, c.g), c.b);
    if (lo < 0.0) c = l + (c - l) * l / max(l - lo, 1e-5);
    if (hi > 1.0) c = l + (c - l) * (1.0 - l) / max(hi - l, 1e-5);
    return c;
}
vec3 setLum(vec3 c, float l) { return clipColour(c + (l - lum(c))); }
float sat(vec3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }
vec3 setSat(vec3 c, float s) {
    float lo = min(min(c.r, c.g), c.b), hi = max(max(c.r, c.g), c.b);
    return hi > lo ? (c - lo) * s / (hi - lo) : vec3(0.0);
}

void main() {
    int f = int(par.w + 0.5);
    if (f > 0) {
        // the filtered backdrop in place of the backdrop, within the mask,
        // by the layer's opacity: nothing under it, nothing to filter
        if (par.y < 0.5) { fragColor = vec4(0.0); return; }
        vec4 was = texture(belowTex, qt_TexCoord0);
        vec4 now = filtered(f, qt_TexCoord0);
        float cover = geo.z > 0.5 ? texture(mask, qt_TexCoord0).a : 1.0;
        int mmode = int(msk.x + 0.5);
        if (mmode > 0) {
            float band = max(msk.y, 0.0);
            float near = 1.0 - smoothstep(band - 0.5, band + 0.5, edgeDistance(qt_TexCoord0));
            cover *= mmode == 1 ? near : 1.0 - near;
        }
        fragColor = mix(was, now, cover * par.z) * qt_Opacity;
        return;
    }
    vec4 s = texture(aboveTex, qt_TexCoord0) * par.z;
    vec4 d = par.y > 0.5 ? texture(belowTex, qt_TexCoord0) : vec4(0.0);
    // the textures are premultiplied; the arithmetic below is not
    vec3 Cs = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
    vec3 Cb = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
    int m = int(par.x + 0.5);
    vec3 B;
    if (m == 13)      B = setLum(setSat(Cs, sat(Cb)), lum(Cb));   // hue
    else if (m == 14) B = setLum(setSat(Cb, sat(Cs)), lum(Cb));   // saturation
    else if (m == 15) B = setLum(Cs, lum(Cb));                    // colour
    else if (m == 16) B = setLum(Cb, lum(Cs));                    // luminosity
    else              B = perChannel(m, Cb, Cs);
    // source-over with the blend applied where the two overlap
    vec3 Cr = (1.0 - d.a) * Cs + d.a * B;
    float ar = s.a + d.a * (1.0 - s.a);
    fragColor = vec4((1.0 - s.a) * d.a * Cb + s.a * Cr, ar) * qt_Opacity;
}
