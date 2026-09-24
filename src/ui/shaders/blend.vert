#version 440
// Quad for BlendRect. Nothing interesting happens here — the effect is
// entirely in the pipeline's blend state (see BlendItem.cpp), which is why
// this needs no access to what is behind it and costs no offscreen texture.
layout(location = 0) in vec2 qt_Vertex;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    vec4 color;
    float qt_Opacity;
};
void main() {
    gl_Position = qt_Matrix * vec4(qt_Vertex, 0.0, 1.0);
}
