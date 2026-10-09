#version 450
#extension GL_ARB_separate_shader_objects: enable

#define MAX_LIGHT_COUNT 40

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;
layout(set=2, binding=0) uniform texture2D cloud_tex; // GLOBALPAN_SKYSHADOW

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

layout(push_constant) uniform PushConstants {
	vec4 light_scale_mode; // xyz: SceneDesc GlobalLightScale, w: 1 if the bound texture is DTX_FULLBRITE
	vec4 fog_colour; // rgb 0..1, w: 1 = fog on
	vec4 fog_range; // x: near, y: far (FOGTABLESTART / FOGTABLEEND), z: depth mode, w: Saturate
	vec4 cloud; // x, y: cloud x / z offset; z, w: 1 / (texture width * x scale), 1 / (texture height * z scale); 0 = none
} pc;

layout(location=0) in vec3 colour_in;
layout(location=1) in vec2 uv_coord_in;
layout(location=2) in vec2 lightmap_uv_in;
layout(location=3) in float lightmapped_in;
layout(location=4) in vec3 dynamic_light_in;
layout(location=5) in float eye_depth_in;
layout(location=6) in vec3 world_position_in;
layout(location=7) in vec3 normal_in;

layout(location=0) out vec4 colour_out;

// D3D linear table fog: 1 at the near distance, 0 at the far one
float FogFactor()
{
	if (pc.fog_colour.w<0.5)
		return 1.0;
	// fog_range.z: 0 = like d3d.ren, whose TL vertices make D3D compare FOGTABLESTART/END with the device depth (0..1), so
	// the game's world-unit ranges leave it unfogged; 1 = by eye distance in world units (console d_FogMode 1)
	float depth=pc.fog_range.z>0.5 ? eye_depth_in : gl_FragCoord.z;
	return clamp((pc.fog_range.y-depth)/(pc.fog_range.y-pc.fog_range.x), 0.0, 1.0);
}

// d3d.ren rebuilds the lightmap of a lit poly every frame (blood2_recon port_notes/world.md 5.2, d3d_BuildLightmap):
// per texel and light within the radius, k = trunc((1 - d^2/r^2) * 63) and I = min(1, LightSaturate * k / 63), and the
// texel gets I * (2c - 255) added. The falloff is quadratic, unlike the vertex lights. Here it's evaluated per pixel
// instead of on the lightmap's 20-unit grid.
vec3 DynamicLightmap()
{
	vec3 light=vec3(0.0);

	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];

		if (obj.flags>0.5 && dot(normal_in, obj.position-world_position_in)<0.01)
			continue;

		vec3 to_light=obj.position-world_position_in;
		float d2=dot(to_light, to_light), r2=obj.radius*obj.radius;
		if (d2>=r2) continue;

		float k=floor((1.0-d2/r2)*63.0);
		light+=(2.0*obj.colour-1.0)*min(1.0, light_list.light_saturate*k/63.0);
	}

	return light;
}

// blood2_recon port_notes/world.md 4: lightmapped polies are two passes, LM * scale, then the texture multiplied over it
// (ZERO / SRCCOLOR), each fogged on its own; fullbright textures add texture * texture alpha in that second pass
// (SRCALPHA / SRCCOLOR). Gouraud polies are texture * pre-lit colour * scale (+ dynamic lights), fogged, with the
// fullbright texels added unfogged by a SRCALPHA / ONE pass. Cloud-shadowed polies (surface flag 0x8000, port_notes/
// sky.md, Panning sky) take the lightmap pass's place with the moving cloud texture times the Gouraud light.
void main()
{
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_coord_in/textureSize(sampler2D(tex, tex_sampler), 0));
	float fog=FogFactor();
	bool fullbright=pc.light_scale_mode.w>0.5;
	bool cloud=lightmapped_in>1.5 && pc.cloud.z!=0.0;

	vec3 colour;
	if ((lightmapped_in>0.5 && lightmapped_in<1.5) || cloud)
	{
		vec3 light;
		if (cloud)
		{
			vec2 cloud_uv=vec2((world_position_in.x+pc.cloud.x)*pc.cloud.z, (world_position_in.z+pc.cloud.y)*pc.cloud.w);
			light=texture(sampler2D(cloud_tex, tex_sampler), cloud_uv).rgb*
				clamp(colour_in*pc.light_scale_mode.xyz+dynamic_light_in, 0.0, 1.0);
		}
		else
		{
			vec3 lightmap=texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_uv_in).rgb;
			light=clamp(lightmap+DynamicLightmap(), 0.0, 1.0)*pc.light_scale_mode.xyz;
		}
		vec3 fogged_light=mix(pc.fog_colour.rgb, light, fog);
		vec3 fogged_texel=mix(pc.fog_colour.rgb, texel.rgb, fog);
		// "Saturate" makes the texture pass SRCBLEND DESTCOLOR: src*dest + dest*src, twice the product; fullbright textures
		// are drawn in their own SRCALPHA / SRCCOLOR batch either way
		if (fullbright)
			colour=fogged_light*fogged_texel+fogged_texel*texel.a;
		else
			colour=fogged_light*fogged_texel*(pc.fog_range.w>0.5 ? 2.0 : 1.0);
	}
	else
	{
		vec3 light=clamp(colour_in*pc.light_scale_mode.xyz+dynamic_light_in, 0.0, 1.0);
		colour=mix(pc.fog_colour.rgb, texel.rgb*light, fog);
		if (fullbright)
			colour+=texel.rgb*texel.a;
	}

	colour_out=vec4(min(colour, vec3(1.0)), 1.0);
}
