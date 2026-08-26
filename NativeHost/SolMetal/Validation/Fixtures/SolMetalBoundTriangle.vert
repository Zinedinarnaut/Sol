#version 450

layout(location = 0) in vec2 position;
layout(location = 1) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;

layout(std140, set = 0, binding = 0) uniform SolMetalTransform
{
    vec4 transform;
};

void main()
{
    gl_Position = vec4(position + transform.xy, transform.z, 1.0);
    fragment_color = vertex_color;
}
