#version 450

// world-space object geometry (models, sprites, ...); lighting is already in the vertex colour

layout(set=0, binding=0) uniform UniformBufferObject {
	mat4 model;
	mat4 view;
	mat4 proj;
} ubo;

layout(location=0) in vec3 position_in;
layout(location=1) in vec4 colour_in;
layout(location=2) in vec2 uv_in;

layout(location=0) out vec4 colour_out;
layout(location=1) out vec2 uv_out;

void main()
{
	gl_Position=ubo.proj*ubo.view*ubo.model*vec4(position_in, 1.0);
	colour_out=colour_in;
	uv_out=uv_in;
}
