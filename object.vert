#version 450

// world-space object geometry (models, world models, sprites, ...); models come lit in the vertex colour (d3d.ren's
// light ramp), world models' Gouraud polies get the dynamic lights added here like the world's

layout(set=0, binding=0) uniform UniformBufferObject {
	mat4 model;
	mat4 view;
	mat4 proj;
} ubo;

#extension GL_GOOGLE_include_directive: require
#include "lighting.glsl"

layout(push_constant) uniform PushConstants {
	vec4 light_scale_mode, fog_colour, fog_range, cloud; // object.frag
	vec4 ambient; // w: lighting kind, 0 pre-lit, 1 model, 2 world polies (world models)
	vec4 directional;
} pc;

layout(location=0) in vec3 position_in;
layout(location=1) in vec4 colour_in;
layout(location=2) in vec2 uv_in;
layout(location=3) in vec3 lightmap_in; // atlas u, v; z = 1 if lightmapped
layout(location=4) in vec3 normal_in; // world space, unit length; 0 where nothing is lit per pixel

layout(location=0) out vec4 colour_out; // as d3d.ren lights it
layout(location=1) out vec2 uv_out;
layout(location=2) out vec3 lightmap_out;
layout(location=3) out float eye_depth_out; // for D3D-style table fog
layout(location=4) out vec3 world_position_out; // for the per-pixel lights
layout(location=5) out vec3 normal_out;
layout(location=6) out vec3 base_colour_out; // the vertex colour without the classic dynamic lights

void main()
{
	vec4 view_pos=ubo.view*ubo.model*vec4(position_in, 1.0);
	gl_Position=ubo.proj*view_pos;
	colour_out=colour_in;
	// world model Gouraud polies: pre-lit colour x GlobalLightScale plus d3d.ren's vertex lights (port_notes/
	// worldmodels.md, Dynamic lights), clamped per vertex like the original
	if (pc.ambient.w>1.5 && lightmap_in.z<0.5)
		colour_out.rgb=clamp(colour_in.rgb+ClassicVertexLight(position_in, normal_in, false), 0.0, 1.0);
	uv_out=uv_in;
	lightmap_out=lightmap_in;
	eye_depth_out=abs(view_pos.z);
	world_position_out=position_in;
	normal_out=normal_in;
	base_colour_out=colour_in.rgb;
}
