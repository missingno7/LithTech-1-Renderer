#version 450
#extension GL_ARB_separate_shader_objects: enable

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;
layout(set=2, binding=0) uniform texture2D cloud_tex; // GLOBALPAN_SKYSHADOW

#define FRAGMENT_SHADER
#extension GL_GOOGLE_include_directive: require
#include "lighting.glsl"

layout(push_constant) uniform PushConstants {
	vec4 light_scale_mode; // xyz: SceneDesc GlobalLightScale, w: 1 if the bound texture is DTX_FULLBRITE
	vec4 fog_colour; // rgb 0..1, w: 1 = fog on
	vec4 fog_range; // x: near, y: far (FOGTABLESTART / FOGTABLEEND), z: depth mode, w: Saturate
	vec4 cloud; // x, y: cloud x / z offset; z, w: 1 / (texture width * x scale), 1 / (texture height * z scale); 0 = none
	vec4 ambient, directional; // object shaders only
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

// blood2_recon port_notes/world.md 4: lightmapped polies are two passes, LM * scale, then the texture multiplied over it
// (ZERO / SRCCOLOR), each fogged on its own; fullbright textures add texture * texture alpha in that second pass
// (SRCALPHA / SRCCOLOR). Gouraud polies are texture * pre-lit colour * scale (+ dynamic lights), fogged, with the
// fullbright texels added unfogged by a SRCALPHA / ONE pass. Cloud-shadowed polies (surface flag 0x8000, port_notes/
// sky.md, Panning sky) take the lightmap pass's place with the moving cloud texture times the Gouraud light.
// With the modern lighting the dynamic lights are evaluated per pixel with N.L wherever the classic ones went, and their
// specular is added on top, fogged away with the surface.
void main()
{
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_coord_in/textureSize(sampler2D(tex, tex_sampler), 0));
	float fog=FogFactor();
	bool fullbright=pc.light_scale_mode.w>0.5;
	bool cloud=lightmapped_in>1.5 && pc.cloud.z!=0.0;

	bool modern=Modern();
	vec3 modern_diffuse=vec3(0.0), modern_specular=vec3(0.0);
	if (modern)
		ModernLights(world_position_in, normalize(normal_in), false, modern_diffuse, modern_specular);
	vec3 vertex_light=modern ? modern_diffuse : dynamic_light_in;

	vec3 colour;
	if ((lightmapped_in>0.5 && lightmapped_in<1.5) || cloud)
	{
		vec3 light;
		if (cloud)
		{
			vec2 cloud_uv=vec2((world_position_in.x+pc.cloud.x)*pc.cloud.z, (world_position_in.z+pc.cloud.y)*pc.cloud.w);
			light=texture(sampler2D(cloud_tex, tex_sampler), cloud_uv).rgb*
				clamp(colour_in*pc.light_scale_mode.xyz+vertex_light, 0.0, 1.0);
		}
		else
		{
			vec3 lightmap=texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_uv_in).rgb;
			vec3 texel_light=modern ? modern_diffuse : ClassicTexelLight(world_position_in, normal_in, true);
			light=clamp(lightmap+texel_light, 0.0, 1.0)*pc.light_scale_mode.xyz;
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
		vec3 light=clamp(colour_in*pc.light_scale_mode.xyz+vertex_light, 0.0, 1.0);
		colour=mix(pc.fog_colour.rgb, texel.rgb*light, fog);
		if (fullbright)
			colour+=texel.rgb*texel.a;
	}

	colour+=modern_specular*Gloss(texel.rgb)*fog;

	colour_out=vec4(min(colour, vec3(1.0)), 1.0);
}
