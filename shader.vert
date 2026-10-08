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
	vec3 position; float pad;
	vec3 colour;
	float radius;
};

layout(set=0, binding=2) uniform LightList {
	uint count; float pad0, pad1, pad2;
	LightObj lights[MAX_LIGHT_COUNT];
} light_list;

layout(location=0) in vec3 position_in;
layout(location=1) in vec3 colour_in; // pre-lit vertex colour, 0..1
layout(location=2) in vec2 uv_in; // texels
layout(location=3) in vec2 lightmap_uv_in; // lightmap atlas, normalised
layout(location=4) in float lightmapped_in; // 1 = lightmapped surface

layout(location=0) out vec3 colour_out;
layout(location=1) out vec2 uv_out;
layout(location=2) out vec2 lightmap_uv_out;
layout(location=3) out float lightmapped_out;
layout(location=4) out vec3 dynamic_light_out;

// d3d.ren adds (c - (255 - c)) * (1 - d/r) per light (blood2_recon port_notes/worldmodels.md, Dynamic lights):
// colours below half darken
vec3 DynamicLight()
{
	vec3 light=vec3(0.0);

	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];

		float distance_to_light=distance(obj.position, position_in);
		if (distance_to_light>=obj.radius) continue;

		light+=(2.0*obj.colour-1.0)*(1.0-distance_to_light/obj.radius);
	}

	return light;
}

void main()
{
	gl_Position=ubo.proj*ubo.view*ubo.model*vec4(position_in, 1.0);

	colour_out=colour_in;
	uv_out=uv_in;
	lightmap_uv_out=lightmap_uv_in;
	lightmapped_out=lightmapped_in;
	dynamic_light_out=DynamicLight();
}
