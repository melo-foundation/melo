#version 440

// One separable Gaussian axis over the words' coverage; a known profile lets
// the following cut be placed by arithmetic. 13 taps at half-sigma, `tapStep`
// in source pixels; outside is empty. Uniforms avoid GLSL builtin names: one
// called `step` silently compiled to nothing.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D src;
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  map;       // this item's texcoord -> source uv: uv = tc * map.xy + map.zw
    vec2  tapStep;   // half a sigma along one axis, in source uv
};

float cov(vec2 uv) {
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return 0.0;
    return texture(src, uv).a;
}

void main() {
    vec2 uv = qt_TexCoord0 * map.xy + map.zw;
    // unit Gaussian at 0, ±0.5σ, ±1σ, ±1.5σ, ±2σ, ±2.5σ, ±3σ; they sum to 1.9979
    const float w[7] = float[7](0.3989, 0.3521, 0.2420, 0.1295, 0.0540, 0.0175, 0.0044);
    float a = cov(uv) * w[0];
    for (int i = 1; i < 7; ++i)
        a += (cov(uv + tapStep * float(i)) + cov(uv - tapStep * float(i))) * w[i];
    a = clamp(a / 1.9979, 0.0, 1.0);
    fragColor = vec4(a);
}
