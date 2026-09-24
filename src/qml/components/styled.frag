#version 440

// Styled fills: procedural colour through glyph coverage, or over a surface.
// Each kind is still at speed 0 and moves above it. The pattern runs in
// WINDOW space, so one rainbow crosses every label in the window rather
// than restarting in each — origin/size say where this item sits.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D mask;
layout(binding = 2) uniform sampler2D shapeMap;
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  colourA;  // the entry's own colour: the base of the kinds that have one
    vec4  pal0, pal1, pal2, pal3, pal4, pal5;   // the palette, up to six stops
    vec4  geo0;     // origin.xy, size.xy — this item in the window, px
    vec4  geo1;     // unit.xy, hasMask, kind
    vec4  par;      // line height in px (0: the whole item), scale, angle (degrees), speed
    float time;     // seconds, the shared clock; the phase is time * speed
    float palN;     // how many stops the palette has; 0 is the kind's classic look
    vec4  msk;      // mask mode (0 all, 1 edge, 2 core), band in px, phase, the field's reach
    float mskSoft;  // how far the band's edge fades, in px; 0 is one pixel
    // A kind's own options: eight floats in the order its Theme table declares
    // (par2 = slots 0-3, par3 = 4-7). Unset options get the table default, so an
    // entry written before an option existed draws unchanged.
    vec4  par2;
    vec4  par3;
    // Corner radii in px, clockwise from top left, when the shape is a rounded
    // rectangle: its distance field is then closed form and exact at any size.
    // -1 means not a rectangle (a glyph, or a shape only EdgeField describes).
    vec4  rad;
};

vec3 hsv2rgb(vec3 c) {
    vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}
// Inigo Quilez's cosine palette
vec3 pal(float t, vec3 a, vec3 b, vec3 c, vec3 d) { return a + b * cos(6.28318 * (c * t + d)); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = p * 2.03 + 17.0; a *= 0.5; }
    return v;
}

// Nearest two mineral cells and a stable identity for each. The
// bounded jitter keeps the search to nine neighbours; no texture or extra
// render pass, even when the picker draws every fill at once.
vec3 cells(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    float first = 8.0, second = 8.0, seed = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 g = vec2(float(x), float(y));
            vec2 id = i + g;
            vec2 site = 0.22 + 0.56 * vec2(hash(id), hash(id + 19.19));
            vec2 d = g + site - f;
            float dd = dot(d, d);
            if (dd < first) { second = first; first = dd; seed = hash(id + 47.7); }
            else second = min(second, dd);
        }
    }
    return vec3(sqrt(first), sqrt(second) - sqrt(first), seed);
}

// Subpixel stars keep their energy instead of flickering on/off as they
// drift. The grid is only a lookup: jitter and sparse occupancy hide it.
float stars(vec2 p, float phase) {
    vec2 id = floor(p);
    float seed = hash(id + 31.4);
    vec2 centre = 0.2 + 0.6 * vec2(hash(id + 7.1), hash(id + 83.2));
    vec2 d = fract(p) - centre;
    float pixel = max(length(fwidth(p)), 0.001);
    float radius = mix(0.018, 0.055, seed);
    float width = max(radius, pixel * 0.65);
    float core = exp(-dot(d, d) / (width * width)) * radius * radius / (width * width);
    float halo = exp(-length(d) * 18.0) * 0.12;
    float twinkle = 0.8 + 0.2 * sin(phase * 0.7 + seed * 30.0);
    return (core + halo) * step(0.82, seed) * twinkle;
}

// A smooth liquid relief, sampled for its normal rather than painted as
// noise. The highlights below are reflections of a studio, not white veins.
float mercuryHeight(vec2 p, float phase) {
    // Time changes the relief itself, not just where the camera sits on a
    // frozen sheet. All three normal samples must see the same phase.
    vec2 w = vec2(sin(p.y * 1.3 + sin(p.x * 0.8 - phase * 0.7) + phase * 0.9),
                  cos(p.x * 1.1 - p.y * 0.6 - phase * 0.8));
    vec2 q = p + w * 1.2 + vec2(0.3 * sin(phase), 0.25 * sin(phase * 0.7));
    // High noise octaves become enormous spikes when differentiated. A
    // three-octave relief keeps reflections smooth instead of crumpled foil.
    return vnoise(q) * 0.65 + vnoise(q * 2.03 + 17.0 + vec2(phase * 0.3, -phase * 0.2)) * 0.22
         + vnoise(q * 4.11 + 34.0 - phase * 0.25) * 0.08 + 0.18 * sin(p.x * 1.7 + p.y + w.x - phase * 1.3);
}

// Compact, C2-continuous cloud lobes and their analytic height gradient.
// Each puff breathes and wanders independently. The support stays inside
// this nine-cell neighbourhood, so crossing a cell never pops a new puff.
vec3 cloudLobes(vec2 p, float phase) {
    vec2 cell = floor(p), f = fract(p);
    float density = 0.0;
    vec2 gradient = vec2(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 g = vec2(float(x), float(y));
            float seed = hash(cell + g + 37.1) * 6.28318;
            vec2 centre = 0.5 + 0.16 * vec2(sin(seed + phase * 0.9), cos(seed * 1.7 - phase * 0.7));
            float radius = 0.93 + 0.18 * sin(seed * 2.3 + phase * 1.1);
            vec2 d = f - g - centre;
            float w = max(0.0, 1.0 - dot(d, d) / (radius * radius));
            density += w * w * w;
            gradient -= 6.0 * d / (radius * radius) * w * w;
        }
    }
    return vec3(density, gradient);
}
vec3 comicClassic(float index) {
    float k = mod(index, 3.0);
    return k < 1.0 ? vec3(1.0, 0.76, 0.16) : k < 2.0 ? vec3(0.08, 0.78, 0.88) : vec3(1.0, 0.28, 0.43);
}

mat2 turn(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }
float gyroid(vec3 p) { return dot(sin(p), cos(p.yzx)); }
vec3 gyroidNormal(vec3 p) {
    vec3 s = sin(p), c = cos(p);
    vec3 n = (c * c.yzx - s * s.zxy) * (gyroid(p) < 0.0 ? -1.0 : 1.0);
    return n / max(length(n), 0.0001);
}

// The palette, sampled cyclically: u in 0..1 runs through the stops and back
// to the first. The classic rainbow when there are none.
// A stop carries its alpha: the wheel's alpha strip on a stop makes the fill
// that much see-through where that stop shows, the way it does on a colour.
vec4 stop(int i) {
    return i == 0 ? pal0 : i == 1 ? pal1 : i == 2 ? pal2 : i == 3 ? pal3 : i == 4 ? pal4 : pal5;
}
// The palette walked once, end to end. palAt() wraps, because the kinds that
// use it repeat; a ramp indexed by something bounded — how far a surface is
// turned from the light — needs its two ends to HOLD instead, or the darkest
// band runs straight back into the lightest at the terminator.
vec4 rampFlat(float x) {
    int n = int(palN + 0.5);
    if (n <= 0) return vec4(colourA.rgb, 1.0);
    // The entry's own colour is the ramp's first knot — the lit pole — and
    // the palette runs away from it. The ALPHA is the palette's throughout,
    // so a transparent stop stays transparent and a base tint still reaches
    // a ramp that has one.
    vec4 first = vec4(colourA.rgb, stop(0).a);
    float f = clamp(x, 0.0, 1.0) * float(n);
    int i = int(f);
    if (i >= n) return stop(n - 1);
    return mix(i == 0 ? first : stop(i - 1), stop(i), clamp(f - float(i), 0.0, 1.0));
}
vec3 rainbowAt(float u) { return hsv2rgb(vec3(fract(u), 0.85, 1.0)); }
vec4 palAt(float u) {
        int n = int(palN + 0.5);
    if (n <= 0) return vec4(rainbowAt(u), 1.0);
    if (n == 1) return stop(0);
    float x = fract(u) * float(n);
    int i = int(x);
    // GLSL 120 has no integer modulo (the compatibility-profile fallback).
    return mix(stop(i), stop(i + 1 < n ? i + 1 : 0), x - float(i));
}
// a ramp, not a cycle: u in 0..1 runs from the first stop to the last
vec4 rampAt(float u, vec3 none0, vec3 none1) {
    int n = int(palN + 0.5);
    if (n <= 0) return vec4(mix(none0, none1, clamp(u, 0.0, 1.0)), 1.0);
    if (n == 1) return stop(0);
        float x = clamp(u, 0.0, 1.0) * float(n - 1);
    int i = int(min(x, float(n - 2)));
    return mix(stop(i), stop(i + 1), x - float(i));
}

// Distance and gradient in one evaluation, after Inigo Quilez: the terms the
// distance needs are the terms its derivative needs, so the normal a bevel
// lights costs almost nothing on top of the distance. .x is the distance,
// .yz the unit gradient.
vec3 sdgBox(vec2 p, vec2 b) {
    vec2 w = abs(p) - b;
    vec2 sg = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    float g = max(w.x, w.y);
    vec2 q = max(w, 0.0);
    float l = length(q);
    return vec3(g > 0.0 ? l : g,
                sg * (g > 0.0 ? q / max(l, 1e-6) : (w.x > w.y ? vec2(1, 0) : vec2(0, 1))));
}
// A rounded box is the box inset by its radius, then offset by it — so the
// gradient is the inset box's, unchanged. Corners are picked by quadrant;
// rad is clockwise from the top left in an item whose y runs DOWN.
vec3 sdgRoundRect(vec2 p, vec2 b, vec4 r) {
    vec2 tb = (p.y < 0.0) ? r.xy : r.wz;
    float rr = (p.x < 0.0) ? tb.x : tb.y;
    rr = clamp(rr, 0.0, min(b.x, b.y));
    vec3 g = sdgBox(p, b - rr);
    return vec3(g.x - rr, g.yz);
}

// Distance belongs to the DRAWN shape, not to the window-space pattern.
// Square surfaces need no texture at all; a mask uses EdgeField's cached
// Euclidean distance. Both paths use logical pixels and the same 31.5px cap.
float edgeDistance(vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 0.0;
    float reach = msk.w > 0.0 ? msk.w : 32.0;   // how far the field was measured
    // A rectangle knows its own distance: no fetch, and no cached field held
    // at a settled size and stretched to the item's current one.
    if (rad.x >= 0.0) {
        vec2 sz = max(geo0.zw, vec2(1.0));
        return clamp(-sdgRoundRect((uv - 0.5) * sz, sz * 0.5, rad).x, 0.0, reach - 0.5);
    }
    if (geo1.z > 0.5) {
        vec2 packed = texture(shapeMap, uv).rg;
        return (packed.r + packed.g / 255.0) * reach;
    }
    vec2 d = min(uv, vec2(1.0) - uv) * geo0.zw;
    return min(min(d.x, d.y), reach - 0.5);
}

// where stop i sits across the item, 0 for the even spread (gradient only)
float stopAt(int i) {
    return i == 0 ? par2.z : i == 1 ? par2.w : i == 2 ? par3.x
         : i == 3 ? par3.y : i == 4 ? par3.z : par3.w;
}
void main() {
    vec2 uv = qt_TexCoord0;
    float scale = par.y, ang = radians(par.z), speed = par.w;
    int kind = int(geo1.w + 0.5);
    // window space in a FIXED unit (800px is one pattern), then scaled, so a
    // fill keeps its size as the window is resized. geo1.x is the unit: the window's width for a
    // preview drawn in its own space, 800 otherwise.
    vec2 p = (geo0.xy + uv * geo0.zw) / max(geo1.x, 1.0) * scale;
    vec2 dir = vec2(cos(ang), sin(ang));
    float t = dot(p, dir);
    // ph (seconds * speed) drives things in time; phs (ph * scale) drives motion,
    // since a pattern unit is 800px / scale and speed is in screen pixels. The
    // layer phase (msk.z, one turn over 0..1) is added after the clock, so two
    // layers of one kind decorrelate at any speed.
    float ph = time * speed + msk.z * 6.28318;
    float phs = ph * scale;
    vec3 c;
    float aMul = 1.0;   // a sampled stop's alpha
    if (kind == 1) {
              // gradient: A to B and back, sweeping
        // the entry's colour, then the palette, cyclic across the sweep; with
        // no palette, the colour to gold and back
        float u = fract(t * par2.x + phs * 0.25);   // repeat
        int n = int(palN + 0.5);
        if (par2.y > 1.5) {
            // in bands: the colour and the stops as flat bands of one width
            // across the item, edge to edge
            vec2 q = (uv - 0.5) * geo0.zw;
            float span = abs(dir.x) * geo0.z + abs(dir.y) * geo0.w;
            float x = clamp(dot(q, dir) / max(span, 1.0) + 0.5, 0.0, 0.9999) * float(n + 1);
            int i = int(x);
            vec4 g = i == 0 || n == 0 ? vec4(colourA.rgb, 1.0) : stop(i - 1); c = g.rgb; aMul = g.a;
        } else if (par2.y > 0.5) {
            // Across the item from the edge the angle starts at; a title bar lit from
            // above is the same gradient at any width. Stop positions are `at 1`..`at 6`
            // (all zero = even spread); placed stops let a ramp hold then fall, which evenly
            // spread stops cannot express, and two at one place draw a hard line.
            vec2 q = (uv - 0.5) * geo0.zw;
            float span = abs(dir.x) * geo0.z + abs(dir.y) * geo0.w;
            float x = clamp(dot(q, dir) / max(span, 1.0) + 0.5, 0.0, 1.0);
            bool placed = par2.z + par2.w + par3.x + par3.y + par3.z + par3.w > 0.0;
            vec4 g = vec4(colourA.rgb, 1.0);
            float was = 0.0;
            vec4 had = g;
            for (int i = 0; i < 6; ++i) {
                if (i >= n) break;
                float even = float(i + 1) / float(n);
                // a stop given no place of its own keeps its even one, so
                // moving one stop moves that stop and not the rest
                float at = placed && stopAt(i) > 0.0 ? max(stopAt(i), was) : max(even, was);
                vec4 here = stop(i);
                if (x <= at || i == n - 1) {
                    g = x >= at ? here : mix(had, here, (x - was) / max(at - was, 0.0001));
                    break;
                }
                was = at; had = here;
            }
            c = g.rgb; aMul = g.a;
        } else if (n <= 0) c = mix(colourA.rgb, vec3(1.0, 0.82, 0.35), 0.5 - 0.5 * cos(6.28318 * u));
        else {
            float x = u * float(n + 1); int i = int(x);
            vec4 s0 = i == 0 ? vec4(colourA.rgb, 1.0) : stop(i - 1);
            vec4 s1 = i >= n ? vec4(colourA.rgb, 1.0) : stop(i);
            vec4 g = mix(s0, s1, x - float(i)); c = g.rgb; aMul = g.a;
        }
    } else if (kind == 2) {
       // rainbow
        c = hsv2rgb(vec3(fract(t + phs * 0.25), 0.85, 1.0));
    } else if (kind == 3) {
        // prism: hue bands with a sheen; reads better than rainbow on words
        float h = fract(t * 2.0 + 0.12 * sin(p.y * 18.0 + phs * 2.0) + phs * 0.3);
        // the palette as cyclic bands; none is the cosine rainbow
        if (palN < 0.5) c = pal(h, vec3(0.6), vec3(0.4), vec3(1.0), vec3(0.0, 0.33, 0.67));
        else { vec4 P = palAt(h); c = P.rgb; aMul = P.a; }
        float s2 = pow(0.5 + 0.5 * sin(t * 30.0 - phs * 6.0), 12.0);
        c = mix(c, vec3(1.0), 0.45 * s2);
    } else if (kind == 4) {
       // foil: silver foil with prismatic streaks
        vec3 silver = colourA.rgb;   // the foil's own colour
        float bandT = t * par2.x + 0.3 * fbm(p * 6.0) + phs * 0.4;   // bands
        float band = pow(0.5 + 0.5 * sin(bandT * 6.28318), 3.0);
        // the streaks run through the palette; none is the prismatic rainbow
        vec3 prism = pal(fract(bandT * 0.5), vec3(0.6), vec3(0.4), vec3(1.0), vec3(0.0, 0.33, 0.67));
        if (palN >= 0.5) { vec4 P = palAt(bandT * 0.5); prism = P.rgb; aMul = mix(1.0, P.a, 0.55 * band); }
        c = mix(silver, prism, 0.55 * band);
        float sheen = pow(0.5 + 0.5 * sin(t * 10.0 - phs * 3.0), 16.0);
        c += vec3(0.35) * sheen;
        float grain = step(0.985, hash(floor(p * 900.0)));
        c += vec3(par2.y) * grain;   // sparkle
    } else if (kind == 5) {
       // lava: domain-warped noise, tint to hot
        vec2 q = vec2(fbm(p * 3.0 + phs * 0.15), fbm(p * 3.0 + vec2(5.2, 1.3) - phs * 0.1));
        vec2 r = vec2(fbm(p * 3.0 + 4.0 * q + vec2(1.7, 9.2) + phs * 0.2),
                      fbm(p * 3.0 + 4.0 * q + vec2(8.3, 2.8) - phs * 0.15));
        float v = fbm(p * 3.0 + 4.0 * r);
        // the hot end runs up the palette with the heat; none is gold
        vec3 cool = colourA.rgb * 0.25, warm = colourA.rgb;
        // Heat is skewed low, so a linear ramp starves the first stop; the curve
        // spreads stops over 0.52..0.72, where the noise's heat lives.
        float heat = par2.x;   // where the hot end starts
        vec4 hotP = rampAt(smoothstep(heat, heat + 0.2, v), vec3(1.0, 0.82, 0.35), vec3(1.0, 0.95, 0.75));
        vec3 hot = hotP.rgb; aMul = hotP.a;
        c = mix(mix(cool, warm, smoothstep(heat - 0.27, heat - 0.02, v)), hot,
                smoothstep(heat - 0.07, heat, v));
    } else if (kind == 6) {       // plasma, in the colour's family
        vec2 s = p * par2.x;   // waves
        float v = sin(s.x + phs) + sin(0.5 * (s.y + phs)) + sin(0.5 * (s.x + s.y + phs))
                + sin(length(s - vec2(5.0)) * 0.7 + phs);
        // through the palette on the swing; none is the classic plasma
        if (palN < 0.5) c = pal(v * 0.25, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.1, 0.2));
        else { vec4 P = palAt(v * 0.25); c = P.rgb; aMul = P.a; }
    } else if (kind == 7) {
       // metal: chrome — sky above a horizon, ground below
        float y = uv.y;
        float hz = par2.x;                                       // horizon
        float env = y < hz ? mix(0.95, 0.55, y / max(hz, 0.01))  // sky, bright to hazy
                           : mix(0.18, 0.5, (y - hz) / max(1.0 - hz, 0.01));   // ground
        env += 0.25 * pow(1.0 - abs(y - hz) * 2.0, 8.0) * (y < hz ? -1.0 : 0.0); // horizon line
        float g = fract(t * 0.6 - phs * 0.3);
        float sheen = pow(max(0.0, 1.0 - abs(g - 0.5) * 4.0), 3.0);
        c = colourA.rgb * (0.3 + 0.9 * env) + vec3(par2.y) * sheen * (y < hz ? 1.0 : 0.4);
    } else if (kind == 8) {
       // fire: rising noise, black to red to yellow to white
        vec2 f = vec2(p.x * 5.0, p.y * 5.0 - phs * 1.5);
        float n = fbm(f) * 0.6 + fbm(f * 2.1 + vec2(3.7, 1.1) - vec2(0.0, phs * 2.5)) * 0.4;
        float h = 1.0 - uv.y;                                  // hotter at the bottom
        float i = clamp(n * par2.x * (0.35 + 0.9 * h) - 0.15, 0.0, 1.0);   // reach
        // black, the colour, then up the palette to the tips; none is gold into white
        c = mix(colourA.rgb * 0.06, colourA.rgb, smoothstep(0.0, 0.45, i));
        // the palette spans the whole of the flame above its base, not the tips
        vec4 F = rampAt(smoothstep(0.3, 0.8, i), vec3(1.0, 0.75, 0.1), vec3(1.0));
        float fw = smoothstep(0.3, 0.6, i);
        c = mix(c, F.rgb, fw); aMul = mix(1.0, F.a, fw);
    } else if (kind == 9) {       // aurora: ribbons of the two colours over night
        vec2 w = vec2(p.x * 2.0 + phs * 0.25, p.y * 5.0);
        float rib = fbm(w + vec2(0.0, 0.6 * fbm(w * 1.7 - phs * 0.2)));
        float bands = pow(0.5 + 0.5 * sin(p.y * par2.x + rib * 9.0 + phs * 0.8), 2.0);   // bands
        // the night from the colour, the ribbons up the palette; none is green to violet
        vec3 night = colourA.rgb * 0.08;
        vec4 G = rampAt(smoothstep(0.15, 0.75, rib), vec3(0.2, 0.95, 0.55), vec3(0.6, 0.25, 0.9));
        vec3 glow = G.rgb; aMul = G.a;
        c = mix(night, glow, clamp(bands * (0.4 + rib), 0.0, 1.0));
    } else if (kind == 11) {      // gloss: the glassy button of a 2001 desktop
        // a bright band across the top half, the colour below it darkening
        // to the bottom, a highlight that slides along, a rim light on top
        // uv.y runs DOWN the item: 0 is the top edge
        float y = uv.y;
        float top = 1.0 - smoothstep(0.42, 0.5, y);
        float body = mix(1.0, 0.55, smoothstep(0.5, 1.0, y));
        vec3 base = colourA.rgb * body;
        vec3 sheen = mix(base, vec3(1.0), 0.45 * (1.0 - y / 0.5));
        c = mix(base, sheen, top);
        float g = fract(t * 0.7 - phs * 0.3);
        c += vec3(0.25) * pow(max(0.0, 1.0 - abs(g - 0.5) * 3.0), 4.0);
        c += vec3(0.08) * (1.0 - smoothstep(0.0, 0.08, y));
    } else if (kind == 12) {      // brushed: metal with the grain of the brush
        vec2 dir = vec2(cos(ang), sin(ang));
        vec2 along = vec2(dir.y, -dir.x);
        float grain = 0.0;
        for (int i = 0; i < 4; i++) {
            float f = pow(2.0, float(i));
            grain += (vnoise(vec2(dot(p, dir) * par2.y * f, dot(p, along) * 6.0 * f + phs)) - 0.5) / f;   // fineness
        }
        float shade = 0.75 + 0.3 * sin(uv.y * 3.14159);
        float band = pow(0.5 + 0.5 * sin(dot(p, along) * 7.0 - phs * 0.5), 6.0);
        c = colourA.rgb * (shade + par2.x * grain) + vec3(par2.z) * band;   // grain, sheen
    } else if (kind == 13) {      // aero: the glass of a 2009 desktop
        // the colour lit from above with a soft horizon a third of the way
        // down, a wide diagonal streak of light drifting across, a bright
        // hairline along the top edge, and a faint fine grain
        float y = uv.y;
        // down to 0, the horizon at the very top edge: smoothstep is undefined
        // where its two edges meet, so the upper one never reaches the lower
        float horizon = max(par2.x, 0.001);
        float lit = mix(1.15, 0.8, smoothstep(0.0, horizon, y)) * mix(1.0, 0.9, smoothstep(horizon, 1.0, y));
        vec3 base = colourA.rgb * lit;
        base = mix(base, vec3(1.0), 0.18 * (1.0 - smoothstep(0.0, horizon * 0.95, y)));
        // the streaks run along the angle: t is p on the angle's direction
        float s1 = pow(0.5 + 0.5 * sin(t * 9.0 - phs * 0.6), 6.0);
        float s2 = pow(0.5 + 0.5 * sin(t * 23.0 + 1.3 - phs * 0.9), 18.0);
        c = base + vec3(par2.y) * s1 + vec3(par2.y * 0.63) * s2;   // streaks
        c += vec3(0.25) * (1.0 - smoothstep(0.0, 0.06, y));
        c += vec3(0.03) * (vnoise(p * 700.0) - 0.5);
    } else if (kind == 14) {     // agate: translucent strata in a polished mineral
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        vec2 drift = vec2(phs * 0.18, -phs * 0.12);
        vec2 q = s * 3.0 + drift;
        // Counterflow folds the strata; advancing their phase grows new
        // bands through them. At speed zero this is still the same mineral.
        vec2 warp = vec2(fbm(q + vec2(phs * 0.55, -phs * 0.3)),
                         fbm(q + vec2(8.2, 3.4) + vec2(-phs * 0.4, phs * 0.5)));
        float stone = fbm(q + warp * 2.5 + vec2(0.45 * sin(ph * 0.9), 0.4 * sin(ph * 0.7)));
        float layer = stone * 65.0 + fbm(q * 2.1 - phs * 0.3) * 3.0 - ph * 3.5;
        float band = 0.5 + 0.5 * sin(layer);
        float u = 0.5 + 0.5 * sin(layer * 0.28 + ph * 0.25);
        vec3 classic = mix(vec3(0.025, 0.12, 0.19), vec3(0.1, 0.68, 0.61), smoothstep(0.0, 0.55, u));
        classic = mix(classic, vec3(0.84, 0.49, 0.29), smoothstep(0.55, 1.0, u));
        vec4 mineral = rampAt(u, classic, classic);
        aMul = mineral.a;
        // Filter the fine lamination before it becomes subpixel in a tile.
        float fine = (0.5 + 0.5 * sin(layer * 4.0)) * (1.0 - smoothstep(0.6, 3.0, fwidth(layer * 4.0)));
        float milk = pow(band, 12.0);
        c = mix(colourA.rgb * 0.18, mineral.rgb * (0.45 + 0.45 * band + fine * 0.1), 0.85);
        c = mix(c, mix(mineral.rgb, vec3(0.92, 0.94, 0.88), 0.75), milk * 0.75);
        float polish = pow(0.5 + 0.5 * sin(s.x * 4.0 + s.y * 2.0 + stone * 3.0 - phs), 16.0);
        c += vec3(0.18, 0.2, 0.21) * polish;
    } else if (kind == 15) {     // opal: buried colour flakes under a pearly glaze
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        vec2 drift = vec2(phs * 0.07, -phs * 0.045);
        float cloud = fbm(s * 3.5 + drift);
        vec3 flake = cells(s * 13.0 + vec2(cloud * 1.8) + drift);
        // Colour varies within each flake as well as between them. Slow
        // interference changes the fire without making the mineral boil.
        float grain = fbm(s * 24.0 + vec2(cloud * 3.0) + drift);
        float hue = flake.z * 0.4 + cloud * 1.1 + grain * 0.5 + ph * 0.035;
        vec4 fire = palAt(hue);
        if (palN < 0.5) fire.rgb = pal(hue, vec3(0.55), vec3(0.45), vec3(1.0), vec3(0.0, 0.32, 0.67));
        aMul = fire.a;
        float flash = pow(0.5 + 0.5 * sin(grain * 18.0 + cloud * 10.0 + flake.z * 3.0 + ph * 0.32), 3.0);
        // Soften the flake seams at preview sizes; the glaze stays continuous.
        float seam = smoothstep(0.0, max(0.09, fwidth(flake.y) * 1.5), flake.y);
        vec3 pearl = mix(colourA.rgb, vec3(0.72, 0.8, 0.86), 0.6);
        c = mix(pearl * (0.55 + 0.35 * cloud), fire.rgb, (0.3 + 0.6 * flash) * (0.65 + 0.35 * seam));
        float glaze = pow(0.5 + 0.5 * sin(s.x * 5.0 + s.y * 3.0 + cloud * 5.0 - phs * 0.4), 14.0);
        c += vec3(0.24, 0.27, 0.3) * glaze;
    } else if (kind == 16) {     // nebula: emission clouds, dust lanes and two star depths
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        vec2 drift = vec2(phs * 0.045, -phs * 0.025);
        vec2 q = s * 3.2 + drift;
        float warp = fbm(q + vec2(5.2, 1.7));
        float cloud = fbm(q + vec2(warp * 2.8, -warp * 1.8));
        float filaments = 1.0 - abs(2.0 * fbm(q * 2.4 + warp * 3.0 - drift) - 1.0);
        float density = smoothstep(0.28, 0.76, cloud);
        float u = smoothstep(0.32, 0.7, cloud + (warp - 0.5) * 0.3);
        vec3 classic = mix(vec3(0.24, 0.13, 0.65), vec3(0.95, 0.28, 0.48), smoothstep(0.0, 0.55, u));
        classic = mix(classic, vec3(0.35, 0.85, 1.0), smoothstep(0.55, 1.0, u));
        vec4 gas = rampAt(u, classic, classic);
        aMul = gas.a;
        vec3 night = mix(vec3(0.008, 0.012, 0.035), colourA.rgb * 0.08, 0.45);
        float dust = smoothstep(0.42, 0.68, fbm(q * 1.7 + vec2(14.3, 2.8)));
        c = night + gas.rgb * density * (0.45 + 0.75 * pow(filaments, 3.0));
        c *= 1.0 - dust * 0.75;
        c += gas.rgb * pow(density, 3.0) * 0.3;
        float st = stars(s * 38.0 + drift * 0.55, ph) + stars(s * 67.0 - drift * 0.3 + 17.0, ph) * 0.45;
        c += mix(gas.rgb, vec3(0.9, 0.95, 1.0), 0.8) * st;
    } else if (kind == 17) {     // mercury: a liquid mirror reflecting softboxes
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x))) * 4.0 + vec2(phs * 0.32, -phs * 0.26);
        float h = mercuryHeight(s, ph);
        // A fixed material-space step keeps the relief the same on a glyph
        // and a full window. Screen-space derivatives would flatten previews.
        float e = 0.025;
        vec2 slope = vec2(mercuryHeight(s + vec2(e, 0.0), ph) - h,
                          mercuryHeight(s + vec2(0.0, e), ph) - h) / e;
        vec3 normal = normalize(vec3(-slope * (1.6 + 0.25 * sin(ph)), 1.0));
        vec3 r = reflect(vec3(0.0, 0.0, -1.0), normal);
        float horizon = smoothstep(-0.12, 0.06, r.y);
        float env = mix(0.035, 0.55 + 0.3 * r.y, horizon);
        float box = exp(-pow(abs(r.x + 0.32 - 0.18 * sin(ph * 0.85)) * 3.5, 4.0)) * smoothstep(-0.1, 0.2, r.y);
        float strip = exp(-pow(abs(r.x - 0.65 - 0.2 * sin(ph * 1.2)) * 14.0, 2.0)) * (0.4 + 0.6 * max(r.y, 0.0));
        float u = 0.5 + 0.5 * sin((r.x + r.y) * 3.0);
        vec4 metal = rampAt(u, vec3(0.32, 0.39, 0.48), vec3(0.92, 0.96, 1.0));
        aMul = metal.a;
        c = mix(colourA.rgb, metal.rgb, 0.78) * env;
        c += mix(metal.rgb, vec3(1.0), 0.65) * (box * 0.85 + strip * 0.65);
        c += metal.rgb * pow(1.0 - normal.z, 3.0) * 0.3;
    } else if (kind == 18) {     // lucent: layered glass, a softer sibling to aero
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        float y = uv.y;
        float pane = s.x + s.y * 0.42 - phs * 0.06;
        float u = 0.5 + 0.5 * sin(pane * 7.0);
        vec4 tint = rampAt(u, vec3(0.2, 0.56, 0.7), vec3(0.72, 0.8, 1.0));
        aMul = tint.a;
        float body = mix(1.05, 0.5, smoothstep(0.0, 1.0, y));
        c = mix(colourA.rgb, tint.rgb, 0.22) * body;
        // Wide frosted reflections with crisp inner edges, not repeating
        // chrome stripes. Their different rates suggest two glass layers.
        float a = fract(pane * 0.85 + 0.12) - 0.5;
        float b = fract(pane * 0.62 + s.y * 0.15 + phs * 0.025 + 0.6) - 0.5;
        float haze = exp(-a * a * 24.0);
        float sheet = smoothstep(-0.22, -0.19, a) * (1.0 - smoothstep(0.1, 0.28, a));
        float edge = exp(-pow(abs(a + 0.19) * 100.0, 2.0));
        float back = exp(-b * b * 65.0);
        c += mix(tint.rgb, vec3(1.0), 0.7) * (0.22 * haze + 0.16 * sheet + 0.2 * edge);
        c += tint.rgb * back * 0.17;
        c = mix(c, vec3(0.9, 0.96, 1.0), 0.2 * (1.0 - smoothstep(0.0, 0.38, y)));
        c += vec3(0.2) * (1.0 - smoothstep(0.0, 0.035, y));
        c += tint.rgb * 0.12 * smoothstep(0.94, 1.0, y);
    } else if (kind == 19) {     // gyroid: a turning, continuous 3D labyrinth
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        vec3 origin = vec3((s - vec2(0.5, 0.35)) * 8.0, -3.2);
        vec3 ray = vec3(0.0, 0.0, 1.0);
        mat2 spin = turn(ph * 0.7 + 0.35), tilt = turn(ph * 0.45 + 0.4);
        origin.xz = spin * origin.xz; ray.xz = spin * ray.xz;
        origin.yz = tilt * origin.yz; ray.yz = tilt * ray.yz;
        origin += vec3(phs * 0.2, 0.0, phs * 0.12);
        float wall = 0.22 + 0.08 * sin(ph * 1.1);
        float travel = 0.0;
        vec3 hit = origin;
        // The field's gradient is bounded by sqrt(12); divide by 3.5 so
        // steps cannot leap through a wall. An analytic normal avoids six
        // more field evaluations at every pixel. No textures or extra pass.
        for (int i = 0; i < 48; ++i) {
            hit = origin + ray * travel;
            float d = abs(abs(gyroid(hit)) - wall) / 3.5;
            if (d < 0.002 || travel > 6.0) break;
            travel += d;
        }
        vec3 n = gyroidNormal(hit);
        vec3 light = normalize(vec3(-0.5, -0.7, -1.0));
        // Light rotates with the camera, so a turning sheet catches it.
        light.xz = spin * light.xz; light.yz = tilt * light.yz;
        float diffuse = max(dot(n, light), 0.0);
        float spec = pow(max(dot(n, normalize(light - ray)), 0.0), 48.0);
        float rim = pow(1.0 - abs(dot(n, ray)), 3.0);
        float u = dot(hit, vec3(0.17, 0.13, 0.11)) + ph * 0.12;
        vec4 enamel = palAt(u);
        if (palN < 0.5) enamel.rgb = pal(u, vec3(0.55), vec3(0.4), vec3(1.0), vec3(0.0, 0.25, 0.55));
        aMul = enamel.a;
        // Rays grazing a distant wall may exhaust the budget. Fade those
        // misses into the cavity instead of shading false, stair-stepped hits.
        // Use the SAME distance units as the marcher, and start beyond its
        // acceptance threshold: fading accepted hits draws iteration contours.
        float residual = abs(abs(gyroid(hit)) - wall) / 3.5;
        float resolved = 1.0 - smoothstep(0.003, 0.015, residual);
        float depth = exp(-travel * 0.3) * resolved;
        float ao = clamp(abs(gyroid(hit + n * 0.45)) * 1.5, 0.3, 1.0);
        c = mix(colourA.rgb, enamel.rgb, 0.82) * (0.18 + diffuse * 0.82) * ao;
        c += mix(enamel.rgb, vec3(1.0), 0.7) * (spec * 0.8 + rim * 0.22);
        c = mix(colourA.rgb * 0.04, c, depth);
    } else if (kind == 20) {     // kaleido: mirrored glass folding through itself
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x))) - vec2(0.5, 0.35);
        float radius = length(s);
        // atan(0, 0) is undefined. At the centre the sector is immaterial.
        float angle = radius > 0.0001 ? atan(s.y, s.x) : 0.0;
        float sector = 0.392699;
        float folded = abs(mod(angle + ph * 0.55, sector * 2.0) - sector);
        vec2 q = vec2(cos(folded), sin(folded)) * radius * 6.0;
        q += vec2(0.28 * sin(ph * 0.9), 0.22 * cos(ph * 0.7));
        vec3 glass = vec3(0.0);
        float alphaSum = 0.0, weightSum = 0.0;
        // Three independently turning cuts make a deep optical pattern, not
        // a single spinning bitmap. Widths track pixels in the tiny gallery.
        for (int i = 0; i < 3; ++i) {
            float k = float(i);
            q = turn(0.65 + k * 0.35 + ph * (0.22 + k * 0.07)) * abs(q) - vec2(0.55, 0.27);
            vec2 tile = fract(q) - 0.5;
            float diagonal = tile.x + tile.y;
            float cut = min(abs(diagonal) * 0.7071, min(0.5 - abs(tile.x), 0.5 - abs(tile.y)));
            float aa = max(fwidth(cut), 0.003);
            float edge = 1.0 - smoothstep(0.006, 0.006 + aa * 1.5, cut);
            float seed = hash(floor(q) + vec2(k * 17.0, step(0.0, diagonal) * 13.0));
            float hue = seed * 0.8 + radius * 0.35 + k * 0.23 - ph * 0.14;
            vec4 gem = palAt(hue);
            if (palN < 0.5) gem.rgb = pal(hue, vec3(0.55), vec3(0.45), vec3(1.0), vec3(0.0, 0.3, 0.65));
            float facet = 0.6 + 0.4 * sin(seed * 6.28318 + tile.x - tile.y + ph * 0.8);
            float glint = pow(max(0.0, sin(seed * 17.0 + ph * 1.2)), 12.0);
            // A clear foreground cut over two faint internal reflections:
            // equal-weight soft colour fields just turn into a blurry rosette.
            float weight = i == 0 ? 0.64 : i == 1 ? 0.26 : 0.1;
            glass += (gem.rgb * (0.45 + 0.55 * facet) * (1.0 - edge * 0.65)
                    + mix(gem.rgb, vec3(1.0), 0.6) * edge * glint * 0.65) * weight;
            alphaSum += gem.a * weight; weightSum += weight;
            q *= 1.45;
        }
        aMul = alphaSum / weightSum;
        c = colourA.rgb * 0.1 + glass;
    } else if (kind == 21) {     // raster: phosphor pixels, cascading light and afterglow
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x))) * par2.x;   // pixels
        vec2 id = floor(s), f = fract(s) - 0.5;
        float column = hash(vec2(id.x, 7.3));
        float life = max(par2.y, 2.0);                             // trail
        float age = mod(phs * 12.0 - id.y + column * life, life);
        // Continuous attack and decay: no random per-frame flicker. Staggered
        // columns carry luminous heads with long, dim memory behind them.
        float trail = smoothstep(0.0, 0.65, age) * exp(-age * 0.48);
        float echo = smoothstep(0.0, 0.65, mod(age + life * 0.39, life)) * exp(-mod(age + life * 0.39, life) * 0.65) * 0.25;
        float wave = 0.5 + 0.5 * sin(id.x * 0.24 + id.y * 0.17 - ph * 1.4);
        float energy = 0.07 + trail * 1.4 + echo + pow(wave, 6.0) * 0.18;
        vec4 phosphor = palAt(column * 0.6 + id.y * 0.018 + ph * 0.1);
        if (palN < 0.5) phosphor.rgb = mix(vec3(0.08, 0.85, 0.52), vec3(1.0, 0.48, 0.08),
                                         0.5 + 0.5 * sin(id.x * 0.31 + ph * 0.3));
        aMul = phosphor.a;
        float d = length(max(abs(f) - vec2(0.22, 0.28), vec2(0.0))) - 0.08;
        float aa = max(length(fwidth(s)) * 0.5, 0.01);
        float pixel = 1.0 - smoothstep(-aa, aa, d);
        float lens = exp(-dot(f - vec2(-0.1, -0.13), f - vec2(-0.1, -0.13)) * 24.0);
        // Below a pixel per cell, blend to its average coverage rather than
        // letting the black gaps crawl over the text.
        float resolved = 1.0 - smoothstep(0.5, 1.5, max(fwidth(s.x), fwidth(s.y)));
        pixel = mix(0.55, pixel, resolved);
        c = colourA.rgb * 0.08 + phosphor.rgb * energy * pixel;
        c += mix(phosphor.rgb, vec3(1.0), 0.7) * trail * lens * 0.38 * resolved;
        c += phosphor.rgb * trail * exp(-dot(f, f) * 3.0) * 0.15;
    } else if (kind == 27) {     // cloud: softly lit, billowing cotton rather than noisy smoke
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        // Wind moves the field; billow changes its shape. Neither changes
        // the bounded support of cloudLobes, so no puff pops at a cell seam.
        vec3 puff = cloudLobes(s * par2.x + vec2(-phs * 0.28, phs * 0.1) * par3.z, ph * par3.y);
        float density = puff.x * par2.y;
        float soft = max(par2.z, 0.2);
        float u = smoothstep(max(0.0, 0.575 - 0.425 * soft), 0.575 + 0.425 * soft, density);
        vec4 vapour = rampAt(u, mix(colourA.rgb, vec3(0.72, 0.8, 0.92), 0.8), vec3(1.0, 0.98, 0.94));
        aMul = vapour.a;
        vec3 normal = normalize(vec3(-puff.yz * par2.w, 1.0));
        vec2 sun = turn(radians(par3.x)) * vec2(-0.5, -0.7);
        float light = max(dot(normal, normalize(vec3(sun, 0.85))), 0.0);
        vec3 sky = mix(colourA.rgb, vec3(0.7, 0.83, 0.98), 0.45);
        vec3 cotton = mix(vapour.rgb, vec3(1.0, 0.99, 0.96), 0.35) * (1.02 - par3.w + light * par3.w);
        c = mix(sky * 0.85, cotton, smoothstep(max(0.0, 0.39 - 0.31 * soft), 0.39 + 0.31 * soft, density));
    } else if (kind == 29) {     // comic: inked colour blocks and breathing Ben-Day dots
        vec2 s = vec2(t, dot(p, vec2(-dir.y, dir.x)));
        float wave = s.x * 7.0 + s.y * 5.0 + sin(s.y * 4.0 - ph * 0.7) * 1.2 - ph * 2.4;
        float bands = (0.5 + 0.5 * sin(wave)) * 6.0;
        float boundary = floor(bands + 0.5);
        float aa = max(fwidth(bands) * 0.65, 0.002);
        vec4 previous = palAt((boundary - 1.0) / 6.0), next = palAt(boundary / 6.0);
        if (palN < 0.5) { previous.rgb = comicClassic(boundary - 1.0); next.rgb = comicClassic(boundary); }
        vec4 print = mix(previous, next, smoothstep(-aa, aa, bands - boundary));
        aMul = print.a;
        c = mix(colourA.rgb, print.rgb, 0.9);
        // Pixel-sized print dots survive the small tiles and glyphs; average
        // their coverage when scale pushes them below the pixel grid.
        vec2 screen = s * max(geo1.x, 1.0) / 6.0;
        vec2 f = fract(screen) - 0.5;
        float radius = 0.11 + 0.21 * (0.5 + 0.5 * sin(s.x * 8.0 - s.y * 11.0 + ph * 3.0));
        float pixel = max(length(fwidth(screen)) * 0.5, 0.01);
        float dots = 1.0 - smoothstep(radius - pixel, radius + pixel, length(f));
        dots = mix(dots, 3.14159 * radius * radius, smoothstep(0.6, 1.4, pixel));
        float line = 1.0 - smoothstep(0.025, 0.025 + aa, abs(bands - boundary));
        // The wave's extrema turn back into the SAME band: inking those
        // stationary gradients produces huge black patches, not boundaries.
        line *= smoothstep(0.12, 0.4, bands) * (1.0 - smoothstep(5.6, 5.88, bands));
        float inkWeight = par.x > 0.0 ? mix(0.5, 1.0, smoothstep(24.0, 64.0, par.x)) : 1.0;
        c = mix(c, vec3(0.035, 0.03, 0.07), max(dots * 0.85, line * 0.95) * inkWeight);
    } else if ((kind >= 22 && kind <= 26) || kind == 28 || kind == 30 || kind == 31) {
        float d = edgeDistance(uv);
        // A glyph gets a glyph-sized edge, not one based on a paragraph's
        // bounding rectangle. Icons and surfaces use their smaller dimension.
        float unit = par.x > 0.0 ? par.x : min(geo0.z, geo0.w);
        // ...unless the theme names the width in pixels (`edge`, slot 3 of every
        // shape-aware kind), for a bevel of fixed depth on any size. Auto (par3.x) is
        // that share times a percentage (par3.y); literal is par2.w px. Neither reads
        // auto at 100.
        float autoW = clamp(min(unit * 0.12, 8.0) * scale, 0.65, 24.0);
        float width = par3.x > 0.5 || par3.y <= 0.0 ? autoW * max(par3.y, 1.0) / 100.0 : max(par2.w, 0.5);
        // Cel thresholds magnify tiny normal changes in a rasterised curve, so a wider
        // stencil smooths the light. A dome reads the normal across the whole shape
        // and has its own slots, so its stencil does not come from edge width.
        float normalStep = kind == 31 ? 1.5
                         : kind == 28 ? clamp(width * 0.4, 1.5, 3.0) : clamp(width * 0.25, 1.0, 2.0);
        vec2 texel = vec2(normalStep) / max(geo0.zw, vec2(1.0));
        // Sobel normals smooth pixel-grid steps without bending the contours. The
        // rectangle's gradient is exact from its distance terms, skipping nine
        // dependent fetches.
        vec2 outward;
        float slope;
        if (rad.x >= 0.0) {
            vec2 sz = max(geo0.zw, vec2(1.0));
            vec3 sdg = sdgRoundRect((uv - 0.5) * sz, sz * 0.5, rad);
            outward = sdg.yz;
            // A measured field has no gradient past its reach, so `heading` falls to 0
            // there; the closed form is flattened at the same reach so its interior does
            // not take a different palette stop.
            float fr = msk.w > 0.0 ? msk.w : 32.0;
            slope = (-sdg.x) < fr - 0.5 ? 8.0 * normalStep : 0.0;
        } else {
            float tl = edgeDistance(uv - texel), br = edgeDistance(uv + texel);
            float tr = edgeDistance(uv + vec2(texel.x, -texel.y));
            float bl = edgeDistance(uv + vec2(-texel.x, texel.y));
            float l = edgeDistance(uv - vec2(texel.x, 0.0)), r = edgeDistance(uv + vec2(texel.x, 0.0));
            float up = edgeDistance(uv - vec2(0.0, texel.y)), down = edgeDistance(uv + vec2(0.0, texel.y));
            vec2 gradient = vec2(tl + 2.0 * l + bl - tr - 2.0 * r - br,
                                 tl + 2.0 * up + tr - bl - 2.0 * down - br);
            slope = length(gradient);
            outward = gradient / max(slope, 0.0001);
        }
        float heading = slope > 0.001 ? atan(outward.y, outward.x) : 0.0;
        float lightAngle = ang - 2.35619 + ph * 1.2;
        vec2 lightDir = vec2(cos(lightAngle), sin(lightAngle));
        vec4 ink = palAt(heading / 6.28318 + 0.5 + ph * 0.12);
        if (palN < 0.5) ink.rgb = mix(colourA.rgb, vec3(0.8, 0.92, 1.0), 0.65);
        aMul = ink.a;
        if (kind == 22) {        // bevel: a rounded raised edge, lit from its normal
            float edge = clamp(1.0 - d / width, 0.0, 1.0);
            float direction = par3.w > 0.5 ? -1.0 : 1.0;
            vec3 normal = normalize(vec3(outward * edge * par2.x * direction, sqrt(max(0.02, 1.0 - edge * edge))));
            vec3 light = normalize(vec3(lightDir * 1.2, 1.0));
            float diffuse = max(dot(normal, light), 0.0);
            float spec = pow(max(dot(normal, normalize(light + vec3(0.0, 0.0, 1.0))), 0.0), max(par2.z, 2.0));
            // At height zero the tint and highlight flatten with the normal.
            float shoulder = edge * clamp(par2.x, 0.0, 1.0);
            c = mix(colourA.rgb, ink.rgb, shoulder * 0.2) * (par3.z + diffuse * 0.85);
            c += mix(ink.rgb, vec3(1.0), 0.65) * spec * shoulder * par2.y;
        } else if (kind == 23) { // contour: equidistant waves flowing inward from every outline
            float phase = d / max(0.9, width * 0.8) - ph * 0.9 + ang / 6.28318;
            float ring = pow(0.5 + 0.5 * cos(phase * 6.28318), 8.0);
            ring = mix(0.2, ring, 1.0 - smoothstep(0.2, 0.6, fwidth(phase)));
            ink = palAt(d / 24.0 - ph * 0.14 + ang / 6.28318);
            if (palN < 0.5) ink.rgb = pal(d / 24.0 - ph * 0.14,
                                        vec3(0.55), vec3(0.4), vec3(1.0), vec3(0.0, 0.25, 0.5));
            aMul = ink.a;
            // how far in the rings go: the field's whole reach, or the depth
            // the theme names (`depth`, slot 2) with the last fifth a fade
            float deep = par3.z > 0.5 || par3.w <= 0.0 ? 31.0 * max(par3.w, 1.0) / 100.0 : max(par2.z, 1.0);
            float within = 1.0 - smoothstep(deep * 0.78, deep, d);
            c = colourA.rgb * 0.55 + ink.rgb * within * (0.08 + ring * 0.7);
        } else if (kind == 24) { // rim: a moving glint wrapping the actual perimeter
            float rim = exp(-d / max(0.7, width * 0.5));
            float inner = exp(-abs(d - width * 1.15) * 2.0 / max(width, 1.0));
            float shine = pow(max(dot(outward, lightDir), 0.0), 8.0);
            c = colourA.rgb * (0.4 + 0.15 * smoothstep(0.0, width, d));
            c += ink.rgb * (rim * 0.5 + inner * 0.12);
            c += mix(ink.rgb, vec3(1.0), 0.7) * rim * shine * 0.9;
        } else if (kind == 25) { // trace: luminous heads and tails running along outlines
            vec2 pos = (uv - 0.5) * geo0.zw;
            vec2 boundary = pos + outward * d;
            vec2 tangent = vec2(-outward.y, outward.x);
            float radius = max(length(geo0.zw * 0.5), 1.0);
            // Tangent distance moves the streak along a straight side (a normal-angle
            // sweep alone lights the whole side at once); the angular term carries it round
            // curves. Three integer turns keep atan's wrap seamless.
            float along = (heading + dot(boundary, tangent) / radius) / 6.28318 * 3.0;
            float age = fract(ph * 1.8 - along - ang / 6.28318);
            float tail = smoothstep(0.0, 0.04, age) * exp(-age * 8.0);
            float head = exp(-pow(abs(age - 0.055) / 0.035, 2.0)) * smoothstep(0.0, 0.025, age);
            float band = exp(-pow(abs(d - width * 0.35) / max(0.65, width * 0.3), 2.0));
            if (palN < 0.5) ink.rgb = mix(vec3(0.08, 0.65, 1.0), vec3(1.0, 0.58, 0.12),
                                         0.5 + 0.5 * sin(heading + ph * 1.7));
            c = colourA.rgb * 0.35 + ink.rgb * exp(-d / max(width * 0.8, 0.7)) * 0.12;
            c += ink.rgb * band * tail * 1.8;
            c += mix(ink.rgb, vec3(1.0), 0.8) * band * head * 0.8;
        } else if (kind == 26) { // tidal: sloshing liquid, with a meniscus at every wall
            vec2 pos = (uv - 0.5) * geo0.zw;
            float along = dot(pos, dir), vertical = dot(pos, vec2(-dir.y, dir.x));
            float span = max(1.0, (abs(dir.y) * geo0.z + abs(dir.x) * geo0.w) * 0.5);
            float wavelength = max(12.0, width * 8.0);
            float wave = sin(along * 6.28318 / wavelength - ph * 4.2)
                       + 0.35 * sin(along * 10.6814 / wavelength + ph * 3.0);
            wave *= min(span * 0.1, width * 0.5);
            float level = -span * 0.62 * sin(ph * 2.1);
            // Distance raises the liquid against curved walls and the inside
            // of letters too. A clipped world-space wave cannot do that.
            float meniscus = exp(-d / max(0.8, width * 0.8)) * width * 0.7;
            float depth = vertical - level - wave + meniscus;
            float aa = max(fwidth(depth), 0.7);
            float wet = smoothstep(-aa, aa, depth);
            ink = palAt(vertical / (span * 2.0) + 0.5 + ph * 0.12);
            if (palN < 0.5) ink.rgb = mix(vec3(0.04, 0.35, 0.7), vec3(0.12, 0.85, 0.8),
                                         0.5 + 0.5 * sin(vertical / span * 2.0 + ph * 0.5));
            aMul = ink.a;
            vec3 air = mix(colourA.rgb * 0.3, ink.rgb * 0.2, 0.15);
            vec3 water = mix(colourA.rgb, ink.rgb, 0.75)
                       * (0.5 + 0.3 * exp(-max(depth, 0.0) / max(8.0, span * 0.7)));
            c = mix(air, water, wet);
            float foam = exp(-abs(depth) / max(0.6, width * 0.15));
            float wall = exp(-d / max(0.7, width * 0.45)) * wet;
            float ripple = pow(0.5 + 0.5 * sin(depth / max(1.0, width * 0.8) + along * 0.04 + ph * 2.5), 5.0);
            c += mix(ink.rgb, vec3(1.0), 0.75) * (foam * 0.65 + wall * 0.3);
            c += ink.rgb * ripple * wet * 0.15;
        } else if (kind == 28) { // toon: a coloured cel inside a continuous drawn outline
            float edge = clamp(1.0 - d / (width * 1.8), 0.0, 1.0);
            if (par3.w != 1.0) edge = pow(edge, 1.0 / max(par3.w, 0.25));
            // A rounded shoulder, not a vertical black side wall. Weak
            // gradients at the centre of narrow glyph strokes stay face-on.
            float strength = clamp(slope / (8.0 * normalStep), 0.0, 1.0);
            vec3 normal = normalize(vec3(outward * edge * strength, sqrt(max(0.1, 1.0 - edge * edge))));
            vec3 light = normalize(vec3(lightDir * 1.2, 1.0));
            float diffuse = dot(normal, light);
            float aa = max(fwidth(diffuse), 0.008) + par2.z * 0.18;
            float detail = par.x > 0.0 ? smoothstep(24.0, 64.0, par.x) : 1.0;
            // Even a deep cel shadow retains its colour; a near-black shadow
            // reads as a fat second pen.
            float shadow = mix(0.78, clamp(0.48 + par2.y * 0.22, 0.48, 0.9), detail);
            float cel = shadow + (1.0 - shadow) * (0.5 * smoothstep(0.24 - aa, 0.24 + aa, diffuse)
                                                + 0.5 * smoothstep(0.62 - aa, 0.62 + aa, diffuse));
            // Feather into the face, not across it: softness must not undo
            // the chosen solid reading colour in the middle of a control.
            if (par2.z > 0.0) cel = mix(1.0, cel, smoothstep(0.0, par2.z * 0.5, edge));
            ink = palAt(t + ph * 0.15);
            aMul = palN < 0.5 ? 1.0 : ink.a;
            // No implicit white wash: an unlit flat face is the chosen base.
            vec3 base = palN < 0.5 ? colourA.rgb : mix(colourA.rgb, ink.rgb, 0.7);
            c = base * cel;
            // A pixel-sized pen on controls; fine lettering gets less ink.
            // Its coverage is independent of lighting and reaches zero with
            // the ink control, including partially covered boundary pixels.
            float nib = mix(0.15, max(1.0, width * 0.35), detail) * par2.x;
            float penAA = max(fwidth(d) * 0.5, 0.35);
            float outline = (1.0 - smoothstep(nib - penAA, nib + penAA, d)) * clamp(nib / penAA, 0.0, 1.0);
            // A small highlight INSIDE the pen, rather than a white bevel
            // along every lit side. It follows the curved shoulder smoothly.
            float band = smoothstep(nib + penAA, nib + penAA + 0.6, d)
                       * (1.0 - smoothstep(nib + max(1.0, width * 0.45), nib + max(1.0, width * 0.45) + 0.8, d));
            float spot = smoothstep(0.82, 0.96, dot(outward, lightDir)) * band * strength * detail;
            c = mix(c, mix(base, vec3(1.0), 0.85), spot * par3.z);
            c = mix(c, colourA.rgb * 0.07, outline);
    } else if (kind == 30) { // doodle: paper, boiling pen lines and lively hatching
            vec2 pos = (uv - 0.5) * geo0.zw;
            float wobble = (0.45 * sin(pos.x * 0.17 + pos.y * 0.12 + ph * 4.3 + ang)
                          + 0.3 * sin(pos.x * 0.43 - pos.y * 0.27 - ph * 5.1 - ang)) * min(width * 0.2, 1.0);
            ink = palAt(t + uv.y * 0.2 + ph * 0.1);
            if (palN < 0.5) ink.rgb = colourA.rgb;
            aMul = ink.a;
            vec3 paper = mix(colourA.rgb, vec3(1.0, 0.97, 0.87), 0.86);
            paper = mix(paper, ink.rgb, 0.12);
            vec3 pen = mix(colourA.rgb * 0.15, ink.rgb * 0.35, 0.6);
            float sketch = abs(d - width * 0.2 - 0.25 - wobble);
            float outline = 1.0 - smoothstep(0.3, 0.9, sketch);
            float echo = 1.0 - smoothstep(0.2, 0.8, abs(d - width * 0.8 - 0.6 + wobble * 0.7));
            float hatch = dot(pos, normalize(vec2(1.0, -0.6))) / max(3.0, width * 0.8)
                        + 0.15 * sin(pos.y * 0.04 + ph * 2.0 + ang);
            float stroke = 1.0 - smoothstep(0.06, 0.06 + max(fwidth(hatch) * 0.6, 0.01), abs(fract(hatch + 0.5) - 0.5));
            float hatching = smoothstep(0.4, 0.7, 0.5 + 0.5 * sin(t * 7.0 + p.y * 4.0 + ph * 2.0));
            float inkWeight = par.x > 0.0 ? mix(0.45, 0.95, smoothstep(24.0, 64.0, par.x)) : 0.95;
            c = mix(paper, pen, max(outline * inkWeight, max(echo * 0.45, stroke * hatching * 0.4)));
        } else if (kind == 31) { // dome: the shape lit as a raised dome
            // Ramp indexed by the light rather than a coordinate: lit buttons have curved
            // concentric bands, saturate near the light and go flat on the unlit side,
            // a clamped cosine lobe straight stops cannot reproduce. The theme still names
            // the colours in order. The distance field stops at 31.5px, so a shape wider
            // than twice that domes over its outer band and is flat within.
            float reach = max((par3.w > 0.0 ? par3.w : clamp(unit * 0.5, 1.0, 24.0)) * scale, 1.0);
            float e = clamp(1.0 - d / reach, 0.0, 1.0);
            float tilt = clamp(e * par2.x, 0.0, 1.0);          // depth
            vec3 N = normalize(vec3(outward * tilt, sqrt(max(0.015, 1.0 - tilt * tilt))));
            // `angle` points the way the ramp runs, as a gradient's does, so
            // the light is behind the reader at the opposite side. At speed
            // the light walks round the shape, which is what moves a dome.
            float domeAng = ang + ph * 1.2;
            vec3 L = normalize(vec3(-cos(domeAng), -sin(domeAng), max(par2.y, 0.02)));
            float diffuse = clamp(dot(N, L), 0.0, 1.0);
            // 0 at the lit pole, 1 across the unlit side. `bias` holds the first colour
            // past the light (the broad highlight); `spread` sets how fast the ramp runs
            // after it.
            float x = clamp(((1.0 - diffuse) - par2.z) * par2.w, 0.0, 1.0);
            // The classic look, with no palette: the entry's own colour as a
            // lit solid, rather than the flat slab a ramp of one colour is.
            vec4 ink = rampFlat(x);
            aMul = ink.a;
            c = palN < 0.5 ? colourA.rgb * mix(1.3, 0.45, x) : ink.rgb;
            // Reflected light: a lit solid is never at its darkest on the far
            // rim: light off the surround comes back up at it, so the last
            // band before the outline lifts again.
            if (par3.z > 0.0) {
                float away = clamp(-dot(normalize(vec2(-cos(ang), -sin(ang))), outward), 0.0, 1.0);
                float lip = 1.0 - smoothstep(0.0, max(reach * 0.45, 1.0), d);
                c = mix(c, vec3(1.0), par3.z * away * away * lip);
            }
            // The specular of the era: a tight bright spot on the lit side,
            // over the diffuse rather than replacing it.
            if (par3.x > 0.0) {
                vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
                c += vec3(1.0) * par3.x * pow(clamp(dot(N, H), 0.0, 1.0), max(par3.y, 1.0));
            }
        }
    } else {
        c = colourA.rgb;
    }
    float cover = geo1.z > 0.5 ? texture(mask, uv).a : 1.0;
    // Mask mode: a layer drawn only within msk.y px of the shape's edge, or
    // only beyond it — the distance field is already here, so a stack can
    // put a rim in one fill over an interior in another instead of two
    // fills muddying each other over the whole shape.
    int mmode = int(msk.x + 0.5);
    if (mmode > 0) {
        float band = max(msk.y, 0.0);
        // A soft edge is the band's own: the fade runs `mskSoft` either side
        // of it, so a rim can end in a gradient rather than a line without
        // every other layer having to blur.
        float soft = max(mskSoft, 0.5);
        float near = 1.0 - smoothstep(band - soft, band + soft, edgeDistance(uv));
        cover *= mmode == 1 ? near : 1.0 - near;
    }
    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0) * cover * qt_Opacity * aMul;
}
