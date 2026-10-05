#version 440
// Y, Cb and Cr each from an R8 plane; colorMatrix is the stream's YUV→RGB
// (VideoColorMatrix.h). Output is premultiplied.
layout(location = 0) in vec2 vTex;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    mat4 colorMatrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D yTex;
layout(binding = 2) uniform sampler2D uTex;
layout(binding = 3) uniform sampler2D vTexS;
void main() {
    float y = texture(yTex, vTex).r;
    float u = texture(uTex, vTex).r;
    float v = texture(vTexS, vTex).r;
    vec4 rgb = colorMatrix * vec4(y, u, v, 1.0);
    fragColor = vec4(clamp(rgb.rgb, 0.0, 1.0), 1.0) * qt_Opacity;
}
