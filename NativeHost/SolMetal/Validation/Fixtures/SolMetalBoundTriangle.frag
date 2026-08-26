#version 450

layout(location = 0) in vec4 fragment_color;
layout(location = 0) out vec4 color;

layout(set = 0, binding = 0) uniform sampler2D tint_texture;

void main()
{
    color = fragment_color * texture(tint_texture, vec2(0.5));
}
