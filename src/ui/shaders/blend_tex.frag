#version 440
layout(location = 0) in vec2 vTex;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    vec4 color;
    float qt_Opacity;
    // 1: the source is coverage and only its alpha is read; a glyph layer's RGB
    // carries subpixel fringes that soften blended text. 0: the source is a
    // picture and its colours are used.
    float maskOnly;
};
layout(binding = 1) uniform sampler2D src;
void main() {
    // Stays premultiplied: the textured path's destination factor is
    // OneMinusSrcAlpha, so a transparent texel leaves the destination alone.
    vec4 s = texture(src, vTex);
    if (maskOnly > 0.5) s = vec4(s.a);   // premultiplied white at the coverage
    fragColor = s * vec4(color.rgb, 1.0) * color.a * qt_Opacity;
}
