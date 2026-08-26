#version 450

layout(location = 0) in vec2 fragment_coordinate;
layout(location = 0) out vec4 color;

layout(set = 0, binding = 0) uniform sampler2D source_texture;

void main()
{
    vec3 sample_value = textureLod(
        source_texture,
        fragment_coordinate,
        0.0).rgb;
    color = vec4(
        step(0.28, sample_value.r),
        step(0.25, abs(sample_value.g - 0.5)),
        step(0.64, sample_value.b),
        1.0);
}
