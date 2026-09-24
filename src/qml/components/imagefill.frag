#version 440

// Image placement shares the fill's mask, coordinate space and layer blend.
// Fit 0 is the 800px tile with the inverse-scale convention.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D mask;
layout(binding = 2) uniform sampler2D tex;
layout(binding = 3) uniform sampler2D shapeMap;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 colourA;
    vec4 pal0, pal1, pal2, pal3, pal4, pal5;
    vec4 geo0;     // origin.xy, item size.xy
    vec4 geo1;     // tile unit.xy, hasMask, aspect (h/w)
    vec4 par;      // line height, inverse zoom, angle, speed
    float time;
    float palN;
    vec4 msk;      // mask mode, band, phase, field reach
    vec4 par2;     // fit, anchor (3x3), focus x/y (-1 follows anchor)
    vec4 par3;     // source cuts: left, top, right, bottom
    vec4 rad;
    vec4 imageGeometry; // decoded source size.xy, coordinate-space box.zw
};

float edgeDistance(vec2 uv) {
    float reach = msk.w > 0.0 ? msk.w : 32.0;
    if (rad.x >= 0.0) {
        vec2 halfSize = geo0.zw * 0.5, p = (uv - 0.5) * geo0.zw;
        vec2 tb = p.y < 0.0 ? rad.xy : rad.wz;
        float r = clamp(p.x < 0.0 ? tb.x : tb.y, 0.0, min(halfSize.x, halfSize.y));
        vec2 q = abs(p) - halfSize + r;
        float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        return clamp(-d, 0.0, reach - 0.5);
    }
    if (geo1.z > 0.5) {
        vec2 packed = texture(shapeMap, uv).rg;
        return (packed.r + packed.g / 255.0) * reach;
    }
    vec2 d = min(uv, vec2(1.0) - uv) * geo0.zw;
    return min(min(d.x, d.y), reach - 0.5);
}

// A stretched patch samples its own texels, not its neighbour's half texel.
// Otherwise a one-pixel border bleeds several pixels into a wide centre.
float inSlice(float pixel, float start, float end) {
    float middle = (start + end) * 0.5;
    return clamp(pixel, min(start + 0.5, middle), max(end - 0.5, middle));
}

// Clamp opposing cuts together, not independently: a tiny source or target
// must not invert the centre or make the corners overlap. Keep one source
// pixel for the centre even if the saved cuts exceed the picture's size.
float sliceCoord(float p, float box, float source, vec2 cuts) {
    cuts = max(cuts, vec2(0.0));
    cuts *= min(1.0, max(source - 1.0, 0.0) / max(cuts.x + cuts.y, 0.0001));
    vec2 caps = cuts / max(par.y, 0.1);
    caps *= min(1.0, box / max(caps.x + caps.y, 0.0001));
    float pixel;
    if (p < caps.x) pixel = inSlice(p * cuts.x / max(caps.x, 0.0001), 0.0, cuts.x);
    else if (p > box - caps.y) pixel = inSlice(source - (box - p) * cuts.y / max(caps.y, 0.0001), source - cuts.y, source);
    else pixel = inSlice(cuts.x + (p - caps.x) * (source - cuts.x - cuts.y) / max(box - caps.x - caps.y, 0.0001), cuts.x, source - cuts.y);
    return pixel / max(source, 1.0);
}

void main() {
    if (imageGeometry.x <= 0.0 || imageGeometry.y <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    vec2 uv = qt_TexCoord0, box = max(imageGeometry.zw, vec2(1.0));
    vec2 source = imageGeometry.xy;
    int fit = int(par2.x + 0.5);
    vec2 t;
    float content = 1.0;
    if (fit == 5) {
        // Only the straight edges and centre stretch. Rotation, scrolling and
        // focal placement do not apply to a frame attached to a control.
        t = vec2(sliceCoord(uv.x * geo0.z, geo0.z, source.x, par3.xz),
                 sliceCoord(uv.y * geo0.w, geo0.w, source.y, par3.yw));
    } else {
        float zoom = 1.0 / max(par.y, 0.1);
        vec2 draw;
        if (fit == 0) draw = vec2(geo1.x, geo1.x * max(geo1.w, 0.01)) * zoom;
        else if (fit == 3) draw = box * zoom;
        else if (fit == 4) draw = source * zoom;
        else {
            vec2 ratios = box / source;
            draw = source * (fit == 1 ? max(ratios.x, ratios.y) : min(ratios.x, ratios.y)) * zoom;
        }
        vec2 anchor = vec2(mod(par2.y, 3.0), floor(par2.y / 3.0)) * 0.5;
        vec2 focus = vec2(par2.z < 0.0 ? anchor.x : par2.z, par2.w < 0.0 ? anchor.y : par2.w);
        vec2 origin = anchor * box - focus * draw;
        // Cover never pans beyond the available picture. Contain stays inside
        // its spare space; at larger zoom it obeys the same crop constraint.
        if (fit == 1 || fit == 2)
            origin = clamp(origin, min(vec2(0.0), box - draw), max(vec2(0.0), box - draw));
        vec2 p = geo0.xy + uv * geo0.zw - (origin + focus * draw);
        float a = radians(par.z), ca = cos(a), sa = sin(a);
        t = vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca) / max(draw, vec2(0.0001)) + focus;
        if (fit == 0) {
            t.x += time * par.w * par.y * 0.25 + msk.z;
            t = fract(t);
        } else content = step(0.0, t.x) * step(t.x, 1.0) * step(0.0, t.y) * step(t.y, 1.0);
    }
    vec4 c = texture(tex, t);
    float cover = geo1.z > 0.5 ? texture(mask, uv).a : 1.0;
    int mmode = int(msk.x + 0.5);
    if (mmode > 0) {
        float band = max(msk.y, 0.0);
        float near = 1.0 - smoothstep(band - 0.5, band + 0.5, edgeDistance(uv));
        cover *= mmode == 1 ? near : 1.0 - near;
    }
    fragColor = c * content * cover * qt_Opacity;
}
