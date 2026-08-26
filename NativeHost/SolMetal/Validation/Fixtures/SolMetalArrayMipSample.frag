#version 450

layout(set = 0, binding = 0) uniform sampler2DArray source_texture;

layout(location = 0) out vec4 marker;
layout(location = 5) out vec4 implicit_sample;
layout(location = 6) out vec4 explicit_lod_zero_sample;
layout(location = 7) out vec4 explicit_lod_one_sample;

void main()
{
    const vec3 coordinate = vec3(0.5, 0.5, 0.0);
    marker = vec4(128.0 / 255.0, 0.0, 0.0, 1.0);
    implicit_sample = texture(source_texture, coordinate);
    explicit_lod_zero_sample = textureLod(source_texture, coordinate, 0.0);
    explicit_lod_one_sample = textureLod(source_texture, coordinate, 1.0);
}
