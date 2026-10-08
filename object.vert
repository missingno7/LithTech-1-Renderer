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
layout(location=3) in vec3 lightmap_in; // atlas u, v; z = 1 if lightmapped

layout(location=0) out vec4 colour_out;
layout(location=1) out vec2 uv_out;
layout(location=2) out vec3 lightmap_out;
layout(location=3) out float eye_depth_out; // for D3D-style table fog

void main()
{
	vec4 view_pos=ubo.view*ubo.model*vec4(position_in, 1.0);
	gl_Position=ubo.proj*view_pos;
	colour_out=colour_in;
	uv_out=uv_in;
	lightmap_out=lightmap_in;
	eye_depth_out=abs(view_pos.z);
}
