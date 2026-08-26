#version 450

layout(location = 0) in vec2 fragment_coordinate;
layout(location = 0) out vec4 color;

layout(set = 0, binding = 0) uniform sampler3D source_volume;

void main()
{
    float depth_coordinate = mix(0.125, 0.875, fragment_coordinate.x);
    color = textureLod(
        source_volume,
        vec3(fragment_coordinate, depth_coordinate),
        0.0);
}
