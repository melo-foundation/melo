#version 440
// The SOURCE colour only. What it does to the destination is the blend
// state's business: "invert" draws white with srcColor = OneMinusDstColor,
// so this shader emits white and the hardware returns 1 - dst.
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    vec4 color;
    float qt_Opacity;
};
void main() {
    fragColor = color * qt_Opacity;
}
