#version 450
#extension GL_ARB_separate_shader_objects: enable

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	vec4 light_scale_mode; // xyz: SceneDesc GlobalLightScale, w: 1 if the bound texture is DTX_FULLBRITE
	vec4 fog_colour; // rgb 0..1, w: 1 = fog on
	vec4 fog_range; // x: near, y: far (FOGTABLESTART / FOGTABLEEND), z: depth mode
} pc;

layout(location=0) in vec3 colour_in;
layout(location=1) in vec2 uv_coord_in;
layout(location=2) in vec2 lightmap_uv_in;
layout(location=3) in float lightmapped_in;
layout(location=4) in vec3 dynamic_light_in;
layout(location=5) in float eye_depth_in;

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
// fullbright texels added unfogged by a SRCALPHA / ONE pass.
void main()
{
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_coord_in/textureSize(sampler2D(tex, tex_sampler), 0));
	float fog=FogFactor();
	bool fullbright=pc.light_scale_mode.w>0.5;

	vec3 colour;
	if (lightmapped_in>0.5)
	{
		vec3 light=clamp(texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_uv_in).rgb*pc.light_scale_mode.xyz+dynamic_light_in, 0.0, 1.0);
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
