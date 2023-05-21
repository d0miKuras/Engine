#version 450

layout(location = 0) in vec3 in_position;

layout(set = 0, binding = 0) uniform sceneData{
    mat4 projection;
    mat4 view;
} scene_data;

void main() {
    gl_Position = scene_data.projection * scene_data.view * vec4(in_position, 1.0);
}