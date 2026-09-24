#version 440

// Anisotropic (Kajiya-Kay) specular for a record face:
// pow(sqrt(1 - dot(T,H)^2), n), T the groove tangent. On concentric grooves T is
// independent of rotation, so this term alone is static; a per-sector tangent
// wobble that turns with the disc multiplies it, which stacked translucent layers
// cannot do.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float spin;        // radians
    float lightAngle;  // radians, where the lamp is
    float pitch;       // groove spacing, in turns across the face
    float gain;        // overall strength
    float specExp;     // lobe tightness
    float grooveAmt;   // how much the cut modulates it
    float fresnel;     // gloss toward the rim
    float dust;        // specks and hairs that catch the lamp
    float env;         // the room, reflected in a flat black surface
};

// cheap value noise, enough for groove modulation
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void main() {
    // y up. The texture coordinate runs down the item; left that way, this
    // lamp sits opposite the drawn one and the highlight is mirrored.
    vec2 uv = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * 2.0 - 1.0;
    float r = length(uv);
    if (r > 1.0 || r < 0.31) { fragColor = vec4(0.0); return; }

    float a = atan(uv.y, uv.x);

    // the groove's tangent, in the disc's own frame: tangential, tilted very
    // slightly by the spiral's pitch
    float spiralTilt = 1.0 / (max(pitch, 1.0) * 6.2831853 * max(r, 0.05));
    vec2  T = normalize(vec2(-sin(a) + spiralTilt * cos(a),
                              cos(a) + spiralTilt * sin(a)));

    // half vector, flattened to 2D: the lamp is off to one side
    vec2 H = vec2(cos(lightAngle), sin(lightAngle));

    float d = dot(T, H);
    // a tight exponent gives two scratches rather than a sheen
    float spec = pow(sqrt(max(0.0, 1.0 - d * d)), max(specExp, 1.0));

    // what is cut into the groove, in the DISC's frame — so it turns with the
    // record and sweeps through the lobes
    // Plus, because the y flip reverses which way the angle runs;
    // subtracting would turn the groove field against the disc.
    float ad = a + spin;
    float mod1 = vnoise(vec2(cos(ad), sin(ad)) * 7.0 + vec2(r * 26.0, 0.0));
    float mod2 = vnoise(vec2(cos(ad), sin(ad)) * 17.0 - vec2(0.0, r * 41.0));
    float groove = mix(1.0, 0.35 + 0.95 * mod1 * mod1 + 0.45 * mod2,
                       clamp(grooveAmt, 0.0, 1.0));

    // and the fine ridging itself, also in the disc's frame
    float ridge = 0.82 + 0.18 * sin(r * pitch * 62.8318);

    // Fresnel: a glossy surface reflects more at grazing angles, and on a
    // disc seen face-on the grazing part is the rim, so it multiplies the
    // specular.
    float fres = mix(1.0, 0.18 + 0.82 * pow(clamp(r, 0.0, 1.0), 3.5),
                     clamp(fresnel, 0.0, 1.0));

    float v = spec * groove * ridge * fres * gain;

    // Dust: sparse specks in the disc's frame so they travel, lit mostly
    // where there is light to catch. The noise scale is coarse enough for
    // specks to land on whole pixels; at the tuned settings dust is most of
    // the visible motion.
    if (dust > 0.001) {
        float dn = vnoise(vec2(cos(ad), sin(ad)) * 62.0 + vec2(r * 105.0, 0.0));
        float speck = smoothstep(0.70, 1.0, dn);
        // a floor, so a speck away from the lobes stays dimly lit by the
        // ambient instead of winking on and off at the highlight's edge
        v += speck * (spec * 0.72 + 0.28) * dust * 2.8;
    }

    // The room: flat black vinyl mirrors a dim room as a broad soft ramp.
    // Screen-fixed: the room does not turn with the record.
    if (env > 0.001) {
        vec2 L = vec2(cos(lightAngle), sin(lightAngle));
        float ramp = 0.5 + 0.5 * dot(normalize(uv + 1e-5), L);
        v += pow(ramp, 2.2) * env * 0.09;
    }

    // fade at both edges so it does not end on a hard circle
    v *= smoothstep(0.31, 0.40, r) * (1.0 - smoothstep(0.93, 1.0, r));
    v = clamp(v, 0.0, 1.0);

    // PREMULTIPLIED. The scene graph blends src + dst*(1-srcA), so colour has
    // to arrive already scaled by alpha. Emitting white with the value in the
    // alpha channel instead adds white at full strength wherever the alpha is
    // non-zero, and the disc comes out white.
    fragColor = vec4(vec3(v), v) * qt_Opacity;
}
