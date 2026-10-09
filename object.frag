#version 450

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	// w: 0 normal texture, 1 DTX_FULLBRITE texture on a model (DECAL pass), 2 untextured (lines, polygrids without a
	// sprite, the light-add poly), 3 DTX_FULLBRITE texture on a world surface (added on top)
	vec4 light_scale_mode;
	vec4 fog_colour; // rgb 0..1, w: 1 = fog on (off for lines, fullbright passes and the light-add poly)
	vec4 fog_range; // x: near, y: far
} pc;

layout(location=0) in vec4 colour_in;
layout(location=1) in vec2 uv_in; // normalised, like D3D TL vertices (model UVs are stored that way)
layout(location=2) in vec3 lightmap_in;
layout(location=3) in float eye_depth_in;
layout(location=4) in vec3 world_position_in;

layout(location=0) out vec4 colour_out;

#define MAX_LIGHT_COUNT 40

struct LightObj
{
	vec3 position; float flags;
	vec3 colour;
	float radius;
};

layout(set=0, binding=2) uniform LightList {
	uint count; float light_saturate, pad1, pad2;
	LightObj lights[MAX_LIGHT_COUNT];
} light_list;

// the per-texel dynamic lights of a lightmapped poly (shader.frag DynamicLightmap; blood2_recon port_notes/world.md
// 5.2), for solid world models
vec3 DynamicLightmap()
{
	vec3 light=vec3(0.0);
	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];
		vec3 to_light=obj.position-world_position_in;
		float d2=dot(to_light, to_light), r2=obj.radius*obj.radius;
		if (d2>=r2) continue;
		float k=floor((1.0-d2/r2)*63.0);
		light+=(2.0*obj.colour-1.0)*min(1.0, light_list.light_saturate*k/63.0);
	}
	return light;
}

float FogFactor()
{
	if (pc.fog_colour.w<0.5)
		return 1.0;
	// fog_range.z: 0 = like d3d.ren, whose TL vertices make D3D compare FOGTABLESTART/END with the device depth (0..1), so
	// the game's world-unit ranges leave it unfogged; 1 = by eye distance in world units (console d_FogMode 1)
	float depth=pc.fog_range.z>0.5 ? eye_depth_in : gl_FragCoord.z;
	return clamp((pc.fog_range.y-depth)/(pc.fog_range.y-pc.fog_range.x), 0.0, 1.0);
}

vec3 Fog(vec3 colour, float fog)
{
	return mix(pc.fog_colour.rgb, colour, fog);
}

void main()
{
	float mode=pc.light_scale_mode.w;
	float fog=FogFactor();

	if (mode>1.5 && mode<2.5)
	{
		// no texture bound: the diffuse colour alone
		colour_out=vec4(Fog(colour_in.rgb, fog), colour_in.a);
		return;
	}

	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_in);

	vec3 colour;
	vec3 fullbright_add;
	if (lightmap_in.z>0.5)
	{
		// solid world models are lightmapped like the world: LM * scale, then the texture over it, each fogged
		// the vertex colour is GlobalLightScale here
		vec3 light=clamp(texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_in.xy).rgb+DynamicLightmap(), 0.0, 1.0)*
			colour_in.rgb;
		vec3 fogged_texel=Fog(texel.rgb, fog);
		colour=Fog(light, fog)*fogged_texel;
		fullbright_add=fogged_texel*texel.a;
		// "Saturate": the texture pass is SRCBLEND DESTCOLOR, twice the product (not for fullbright textures' own batch)
		if (mode<2.5 && pc.fog_range.w>0.5)
			colour*=2.0;
	}
	else
	{
		// D3D MODULATE(ALPHA): colour modulated by the texture
		colour=Fog(colour_in.rgb*texel.rgb, fog);
		fullbright_add=texel.rgb*texel.a;
	}

	if (mode>2.5)
	{
		// world fullbright: the fullbright texels are added (alpha marks them, so it isn't opacity)
		colour_out=vec4(min(colour+fullbright_add, vec3(1.0)), colour_in.a);
	}
	else if (mode>0.5)
	{
		// model fullbright: d3d.ren draws the mesh again with DECAL + alpha blending and fog off, i.e. the fullbright
		// texels at full texture colour (blood2_recon port_notes/model.md)
		colour_out=vec4(mix(colour, texel.rgb, texel.a), colour_in.a);
	}
	else
	{
		colour_out=vec4(colour, colour_in.a*texel.a);
	}
}
