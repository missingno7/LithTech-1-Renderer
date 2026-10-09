#version 450
#extension GL_ARB_separate_shader_objects: enable

layout(set=0, binding=0) uniform UniformBufferObject {
	mat4 model;
	mat4 view;
	mat4 proj;
} ubo;

#extension GL_GOOGLE_include_directive: require
#include "lighting.glsl"

layout(location=0) in vec3 position_in;
layout(location=1) in vec3 colour_in; // pre-lit vertex colour, 0..1
layout(location=2) in vec2 uv_in; // texels
layout(location=3) in vec2 lightmap_uv_in; // lightmap atlas, normalised
layout(location=4) in float lightmapped_in; // 0 Gouraud, 1 lightmapped, 2 cloud-shadowed (panning sky)
layout(location=5) in vec3 normal_in; // the surface plane's, unit length

layout(location=0) out vec3 colour_out;
layout(location=1) out vec2 uv_out;
layout(location=2) out vec2 lightmap_uv_out;
layout(location=3) out float lightmapped_out;
layout(location=4) out vec3 dynamic_light_out;
layout(location=5) out float eye_depth_out; // for D3D-style table fog
layout(location=6) out vec3 world_position_out;
layout(location=7) out vec3 normal_out;

void main()
{
	vec4 view_pos=ubo.view*ubo.model*vec4(position_in, 1.0);
	gl_Position=ubo.proj*view_pos;

	colour_out=colour_in;
	uv_out=uv_in;
	lightmap_uv_out=lightmap_uv_in;
	lightmapped_out=lightmapped_in;
	// lightmapped polies get theirs per texel in the fragment shader
	dynamic_light_out=(lightmapped_in>0.5 && lightmapped_in<1.5) ? vec3(0.0) : ClassicVertexLight(position_in, normal_in, true);
	eye_depth_out=abs(view_pos.z);
	world_position_out=position_in;
	normal_out=normal_in;
}
