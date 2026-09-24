#version 440
// Textured variant: same blend state, but the source is another item's
// rendered contents rather than a flat colour. That is what lets TEXT blend —
// Qt draws glyphs with its own materials, which cannot have their pipeline
// state changed, so the text is layered to a texture and this draws it.
layout(location = 0) in vec2 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 vTex;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    vec4 color;
    float qt_Opacity;
    float maskOnly;
};
void main() {
    vTex = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * vec4(qt_Vertex, 0.0, 1.0);
}
