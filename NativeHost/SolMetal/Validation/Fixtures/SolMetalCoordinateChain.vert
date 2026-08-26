#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec2 coordinate;

layout(location = 0) out vec2 fragment_coordinate;

void main()
{
    gl_Position = position;
    fragment_coordinate = coordinate;
}
