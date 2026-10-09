#version 450
#extension GL_ARB_separate_shader_objects: enable

#define MAX_LIGHT_COUNT 40

layout(set=0, binding=0) uniform UniformBufferObject {
	mat4 model;
	mat4 view;
	mat4 proj;
} ubo;

struct LightObj
{
	vec3 position; float flags; // 1: FLAG_DONTLIGHTBACKFACING
	vec3 colour;
	float radius;
};

layout(set=0, binding=2) uniform LightList {
	uint count; float light_saturate, pad1, pad2;
	LightObj lights[MAX_LIGHT_COUNT];
} light_list;

layout(location=0) in vec3 position_in;
layout(location=1) in vec3 colour_in; // pre-lit vertex colour, 0..1
layout(location=2) in vec2 uv_in; // texels
layout(location=3) in vec2 lightmap_uv_in; // lightmap atlas, normalised
layout(location=4) in float lightmapped_in; // 0 Gouraud, 1 lightmapped, 2 cloud-shadowed (panning sky)
layout(location=5) in vec3 normal_in; // the surface plane's

layout(location=0) out vec3 colour_out;
layout(location=1) out vec2 uv_out;
layout(location=2) out vec2 lightmap_uv_out;
layout(location=3) out float lightmapped_out;
layout(location=4) out vec3 dynamic_light_out;
layout(location=5) out float eye_depth_out; // for D3D-style table fog
layout(location=6) out vec3 world_position_out;
layout(location=7) out vec3 normal_out;

// Gouraud polies (and the cloud pass): d3d.ren adds (c - (255 - c)) * (1 - d/r) per light at each vertex (blood2_recon
// port_notes/worldmodels.md, Dynamic lights): colours below half darken. A light with FLAG_DONTLIGHTBACKFACING skips
// polies it is behind (d3d.ren 0x241d0).
vec3 DynamicLight()
{
	vec3 light=vec3(0.0);

	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];

		if (obj.flags>0.5 && dot(normal_in, obj.position-position_in)<0.01)
			continue;

		float distance_to_light=distance(obj.position, position_in);
		if (distance_to_light>=obj.radius) continue;

		light+=(2.0*obj.colour-1.0)*(1.0-distance_to_light/obj.radius);
	}

	return light;
}

void main()
{
	vec4 view_pos=ubo.view*ubo.model*vec4(position_in, 1.0);
	gl_Position=ubo.proj*view_pos;

	colour_out=colour_in;
	uv_out=uv_in;
	lightmap_uv_out=lightmap_uv_in;
	lightmapped_out=lightmapped_in;
	// lightmapped polies get theirs per texel in the fragment shader
	dynamic_light_out=(lightmapped_in>0.5 && lightmapped_in<1.5) ? vec3(0.0) : DynamicLight();
	eye_depth_out=abs(view_pos.z);
	world_position_out=position_in;
	normal_out=normal_in;
}
