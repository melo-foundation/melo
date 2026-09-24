#version 440
// The window's shape, cleared out of what is drawn. The blend is
// Zero / OneMinusSrcAlpha, so writing 1 - coverage keeps covered pixels and
// clears the rest, antialiased at the edge.
layout(location = 0) in vec2 vTex;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D shape;
void main() {
    float coverage = texture(shape, vTex).a;
    fragColor = vec4(0.0, 0.0, 0.0, (1.0 - coverage) * qt_Opacity);
}
