#version 440

// Window border bands, drawn inward from the window's outer edge. All bands
// come from one depth distance smoothed over one device pixel, so straight,
// rounded and cut edges antialias alike. One set of widths serves the whole
// window: a shallower side shows only the inner bands.
// With `region` < 0 all plain-colour bands paint in one pass; a fill or gradient
// band is requested by index and StyledFill draws through it as a mask.
// Distances are in item pixels; `dpr` converts to device pixels.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;      // item px
    vec4  radii;     // outer corners: top left, top right, bottom right, bottom left
    vec4  insets;    // how deep the frame is per side: left, top, right, bottom
    float region;    // -1 every plain band, otherwise the band to draw
    float dpr;
    vec4  tint;      // one band's colour, straight rgba; white for a mask
    vec4  stop1;     // a gradient's stops after tint
    vec4  stop2;
    vec4  stop3;
    vec4  stop4;
    float stops;     // how many of them; 0 is tint alone
    float alongEdge; // 1: the gradient runs round the edge by the way it faces
    float titleH;    // a title bar at the top inside the border: this tall
    float titleRim;  // ...with this much of the frame running up beside it
    float titleFade; // 1: the rest of it fades in beside the title's foot
    vec2  dir;       // a gradient's direction
    float bandsFlat; // 1: the gradient's colours as flat bands, not blended
    float bandN;     // how many bands
    vec4  edges0;    // where bands 0..3 end, deep into the frame
    vec4  edges1;    // ...and 4..7
    vec4  col0;      // the bands' plain colours; alpha 0 is one drawn its own way
    vec4  col1;
    vec4  col2;
    vec4  col3;
    vec4  col4;
    vec4  col5;
    vec4  col6;
    vec4  col7;
    // The window's shape, when it has one (WindowShapeItem): the outer edge is
    // its distance field, nine-sliced by these, instead of the rounded box
    float useShape;
    vec2  shapeBox;
    vec4  shapeSlice;   // left, top, right, bottom
    vec2  fieldSize;    // texels
    float shapeCrop;    // 1: too small for the fixed edges crops the middle
    // How soft the frame's own two edges are, in item px: the outer one at the
    // window's rim and the inner one where the frame gives way to what it goes
    // round. 0 is the single device pixel a hard edge takes. The edges between
    // the bands stay hard.
    float softOut;
    float softIn;
    float softBands;  // ...and how soft every edge BETWEEN the bands is
    float softCurve;  // the shape of the two outer fades: 0 linear, 1 smooth, 2 glow
};
layout(binding = 1) uniform sampler2D field;

vec4 stopAt(int i) { return i == 0 ? tint : i == 1 ? stop1 : i == 2 ? stop2 : i == 3 ? stop3 : stop4; }
float edgeAt(int i) {
    return i < 4 ? (i == 0 ? edges0.x : i == 1 ? edges0.y : i == 2 ? edges0.z : edges0.w)
                 : (i == 4 ? edges1.x : i == 5 ? edges1.y : i == 6 ? edges1.z : edges1.w);
}
vec4 colAt(int i) {
    return i < 4 ? (i == 0 ? col0 : i == 1 ? col1 : i == 2 ? col2 : col3)
                 : (i == 4 ? col4 : i == 5 ? col5 : i == 6 ? col6 : col7);
}

// signed distance to a rounded box centred at the origin, half size b, one
// radius per quadrant (y runs down)
float roundBox(vec2 p, vec2 b, vec4 r) {
    float rr = p.x < 0.0 ? (p.y < 0.0 ? r.x : r.w) : (p.y < 0.0 ? r.y : r.z);
    vec2 q = abs(p) - b + vec2(rr);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}
// a texel of the field, decoded: packed (distance + 32) * 512 in red and green
float fieldTexel(vec2 t) {
    vec4 c = texture(field, (clamp(t, vec2(0.0), fieldSize - 1.0) + 0.5) / fieldSize);
    return (floor(c.r * 255.0 + 0.5) * 256.0 + floor(c.g * 255.0 + 0.5)) / 512.0 - 32.0;
}
// One nine-slice axis: item point to shape box. Cropped keeps the fixed edges
// and drops middle; squeezed scales them. The middle is offset from the nearer
// end rather than scaled, or a distance from an unsliced edge would shrink by
// the stretch.
float axisBox(float x, float s0, float s1, float B, float S) {
    if (shapeCrop > 0.5 && S < s0 + s1) {
        float sp = S * s0 / max(s0 + s1, 0.001);
        return x < sp ? x : B - (S - x);
    }
    float k = S < s0 + s1 ? S / max(s0 + s1, 0.001) : 1.0;
    if (x < s0 * k) return x / max(k, 0.0001);
    if (x > S - s1 * k) return B - (S - x) / max(k, 0.0001);
    float mid = B - s0 - s1;
    float a = x - s0 * k, b = S - s1 * k - x;
    return a <= b ? s0 + min(a, mid * 0.5) : B - s1 - min(b, mid * 0.5);
}
// the shape's signed distance at a point of this item, negative inside as the
// rounded box's is: the point into the shape's box through the nine slices,
// then the four texels around it, decoded before they are blended
float shapeDist(vec2 p) {
    vec4 s = shapeSlice;
    float bx = axisBox(p.x, s.x, s.z, shapeBox.x, size.x);
    float by = axisBox(p.y, s.y, s.w, shapeBox.y, size.y);
    vec2 t = vec2(bx, by) / shapeBox * fieldSize - 0.5;
    vec2 i = floor(t), f = t - i;
    float a = mix(fieldTexel(i), fieldTexel(i + vec2(1.0, 0.0)), f.x);
    float b = mix(fieldTexel(i + vec2(0.0, 1.0)), fieldTexel(i + vec2(1.0, 1.0)), f.x);
    return -mix(a, b, f.y);
}
float inside(float d) { return clamp(0.5 - d * dpr, 0.0, 1.0); }
float ramp(float x) { return clamp(x * dpr + 0.5, 0.0, 1.0); }
// The shape of a fade: straight, eased at both ends, or hugging the far end so
// what is left near the edge is a tail rather than half the colour.
float curved(float t) {
    return softCurve > 1.5 ? t * t : softCurve > 0.5 ? t * t * (3.0 - 2.0 * t) : t;
}
// the frame's own edge, fading inward over `w`
float fadeIn(float x, float w) { return w > 0.0 ? curved(clamp(x / w, 0.0, 1.0)) : 1.0; }
// An edge between two bands, centred on it: what one band loses across the
// fade the next gains, so the pair never sums to more or less than a band.
// Smooth whatever the curve is — an asymmetric one leaves a seam.
float between(float x, float w) {
    if (w <= 0.0) return ramp(x);
    float t = clamp(x / w + 0.5, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    float dOut = useShape > 0.5 ? shapeDist(p) : roundBox(p - size * 0.5, size * 0.5, radii);
    // A title in the top border: the frame's content and top start under the
    // title, and beside the title only the outer `titleRim` bands are drawn.
    float top = titleH + insets.y;
    bool besideTitle = titleH > 0.0 && p.y < titleH;
    float sideW = p.x < size.x * 0.5 ? insets.x : insets.z;
    int bn = int(bandN + 0.5);
    float total = bn > 0 ? edgeAt(bn - 1) : 0.0;

    // Depth measured from the window's own edge, whatever its shape, capped by
    // each side's inset so a shallow side shows the inner bands.
    float dep = -dOut;
    float sd = total - dep;
    sd = max(sd, max(insets.x - p.x, insets.z - (size.x - p.x)));
    sd = max(sd, max(top - p.y, insets.w - (size.y - p.y)));
    float pos = besideTitle ? dep : total - sd;
    // beside the title the innermost band is the one that runs under it, and
    // it is not what fades in at the title's foot
    float fadeCap = bn > 1 ? edgeAt(bn - 2) : total;
    float fade = titleFade > 0.5 && pos < fadeCap
                 ? smoothstep(0.55 * titleH, 0.95 * titleH, p.y) : 0.0;
    float titleK = besideTitle ? max(ramp(titleRim - pos), fade) : 1.0;
    // A soft edge is the whole frame's, not the outermost band's: the bands
    // keep their own hard lines and what fades is the frame's coverage, in
    // from the window's rim and out into what it goes round. Beside a title
    // the frame ends at the rim, so that is the inner edge there.
    float toInner = besideTitle ? titleRim - dep : sd;
    float frameK = fadeIn(max(dep, 0.0), softOut) * fadeIn(max(toInner, 0.0), softIn);

    vec4 acc = vec4(0.0);
    if (region < -0.5) {
        float s = 0.0;
        for (int i = 0; i < 8; ++i) {
            if (i >= bn) break;
            float e = edgeAt(i);
            vec4 c = colAt(i);
            if (c.a > 0.0) {
                float k0 = i == 0 ? ramp(pos - s) : between(pos - s, softBands);
                float k1 = i == bn - 1 ? ramp(e - pos) : between(e - pos, softBands);
                float a = inside(dOut) * k0 * k1 * frameK * titleK * c.a * qt_Opacity;
                acc += vec4(c.rgb * a, a);
            }
            s = e;
        }
    } else {
        int i = int(region + 0.5);
        float s = i == 0 ? 0.0 : edgeAt(i - 1), e = edgeAt(i);
        vec4 col = tint;
        int n = int(stops + 0.5);
        if (n > 0) {
            // Across the frame, outer edge to inner; beside a title, how far
            // in from the outer edge of the side it runs up
            float f = clamp((besideTitle ? dep / max(sideW, 0.001) : pos / max(total, 0.001)), 0.0, 1.0);
            if (alongEdge > 0.5) {
                // ...or round it: the gradient goes by which way the edge
                // faces, the first colour on the edge facing against the angle
                // and the last on the one facing along it — a darker top and a
                // lighter foot, turning with the corners
                vec2 g = useShape > 0.5
                    ? vec2(shapeDist(p + vec2(0.5, 0.0)) - shapeDist(p - vec2(0.5, 0.0)),
                           shapeDist(p + vec2(0.0, 0.5)) - shapeDist(p - vec2(0.0, 0.5)))
                    : vec2(roundBox(p - size * 0.5 + vec2(0.5, 0.0), size * 0.5, radii)
                           - roundBox(p - size * 0.5 - vec2(0.5, 0.0), size * 0.5, radii),
                           roundBox(p - size * 0.5 + vec2(0.0, 0.5), size * 0.5, radii)
                           - roundBox(p - size * 0.5 - vec2(0.0, 0.5), size * 0.5, radii));
                vec2 nrm = length(g) > 1e-4 ? normalize(g) : vec2(0.0);
                f = clamp(0.5 + 0.5 * dot(nrm, dir), 0.0, 1.0);
            }
            if (bandsFlat > 0.5) {
                col = stopAt(int(min(floor(f * float(n + 1)), float(n))));
            } else {
                f *= float(n);
                int k = int(min(f, float(n) - 1.0));
                col = mix(stopAt(k), stopAt(k + 1), clamp(f - float(k), 0.0, 1.0));
            }
        }
        float k0 = i == 0 ? ramp(pos - s) : between(pos - s, softBands);
        float k1 = i == bn - 1 ? ramp(e - pos) : between(e - pos, softBands);
        float a = inside(dOut) * k0 * k1 * frameK * titleK * col.a * qt_Opacity;
        acc = vec4(col.rgb * a, a);
    }
    fragColor = acc;
}
