#version 450

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;

#define FRAGMENT_SHADER
#extension GL_GOOGLE_include_directive: require
#include "lighting.glsl"

layout(push_constant) uniform PushConstants {
	// w: 0 normal texture, 1 DTX_FULLBRITE texture on a model (DECAL pass), 2 untextured (lines, polygrids without a
	// sprite, the light-add poly), 3 DTX_FULLBRITE texture on a world surface (added on top)
	vec4 light_scale_mode;
	vec4 fog_colour; // rgb 0..1, w: 1 = fog on (off for lines, fullbright passes and the light-add poly)
	vec4 fog_range; // x: near, y: far
	vec4 cloud; // world only
	// the modern lighting: rgb the model's ambient light (0..1, no dynamic lights in it); w: lighting kind, 0 pre-lit,
	// 1 model, 2 world polies
	vec4 ambient;
	vec4 directional; // rgb: the model's directional light (light grid), towards light_list.model_light; w: draw id (debug)
	vec4 extra; // x: the model's lamp set (static_lighting.d), -1 for none
} pc;

layout(location=0) in vec4 colour_in;
layout(location=1) in vec2 uv_in; // normalised, like D3D TL vertices (model UVs are stored that way)
layout(location=2) in vec3 lightmap_in;
layout(location=3) in float eye_depth_in;
layout(location=4) in vec3 world_position_in;
layout(location=5) in vec3 normal_in;
layout(location=6) in vec3 base_colour_in;

layout(location=0) out vec4 colour_out;

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
		if (light_list.debug_view!=DEBUG_VIEW_NONE)
		{
			if (colour_in.a<0.5) discard;
			colour_out=DebugOutput(colour_in.rgb, vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0), world_position_in,
				pc.directional.w);
		}
		return;
	}

	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_in);

	// the modern lighting replaces the vertex / texel lights of lit geometry with per-pixel ones (lighting.glsl)
	float kind=pc.ambient.w;
	bool modern=kind>0.5 && dot(normal_in, normal_in)>1e-6 && Modern();
	vec3 modern_diffuse=vec3(0.0), modern_specular=vec3(0.0);
	vec3 normal=dot(normal_in, normal_in)>1e-6 ? normalize(normal_in) : vec3(0.0);
	if (modern)
		ModernLights(world_position_in, normal, kind<1.5, modern_diffuse, modern_specular);

	// world models lose the static light models hide from them, like the world (static_lighting.d)
	vec3 shadow_loss=(kind>1.5 && ShadowsOn()) ? WorldShadowLoss(world_position_in, normal) : vec3(0.0);

	vec3 colour;
	vec3 fullbright_add;
	vec3 debug_light, debug_dynamic; // for the debug views
	if (lightmap_in.z>0.5)
	{
		// solid world models are lightmapped like the world: LM * scale, then the texture over it, each fogged
		// the vertex colour is GlobalLightScale here
		vec3 texel_light=modern ? modern_diffuse : ClassicTexelLight(world_position_in, normal_in, false);
		vec3 lightmap=Unshadowed(texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_in.xy).rgb, shadow_loss);
		vec3 light=clamp(lightmap+texel_light, 0.0, 1.0)*colour_in.rgb;
		debug_light=light;
		debug_dynamic=texel_light;
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
		vec3 light=colour_in.rgb;
		// a model: d3d.ren's 16-step ramp, ambient + directional * step / 16 with step = 8 + 7.94 (N.L), made smooth
		float ramp=clamp(0.5+0.49609375*dot(normal, light_list.model_light.xyz), 0.0, 15.0/16.0);
		vec3 model_static=pc.ambient.rgb+pc.directional.rgb*ramp;
		// the classic dynamic part: what d3d.ren's ramp or vertex lights added over the static light
		debug_dynamic=kind<0.5 ? vec3(0.0) : colour_in.rgb-(kind<1.5 ? model_static : base_colour_in);
		// with the level's lamps known, a model is lit by the actual lamps around it, each from its direction, shadowed
		// where other models hide it; the light grid's light they don't account for stays as the camera-relative term
		int lamp_set=int(pc.extra.x);
		if (modern && kind<1.5 && lamp_set>=0 && static_lighting.counts.w!=0u && uint(lamp_set)<static_lighting.counts.y)
		{
			vec3 lamps=static_lighting.models[lamp_set].residual_count.rgb*ramp;
			uint count=uint(static_lighting.models[lamp_set].residual_count.w);
			bool shadows=ShadowsOn();
			for(uint i=0u; i<count; ++i)
			{
				StaticLamp lamp=static_lighting.models[lamp_set].lamps[i];
				vec3 c=LampAt(lamp, world_position_in);
				if (c==vec3(0.0))
					continue;
				float facing=clamp(0.5+0.49609375*dot(normal, normalize(lamp.pos_radius.xyz-world_position_in)), 0.0, 15.0/16.0);
				float hidden=shadows ? ModelLampShadow(lamp, lamp_set, world_position_in) : 0.0;
				lamps+=c*facing*(1.0-hidden);
				shadow_loss+=c*facing*hidden;
			}
			model_static=pc.ambient.rgb+lamps;
		}
		if (modern && kind<1.5)
			light=clamp(model_static+modern_diffuse, 0.0, 1.0);
		else if (modern)
			light=clamp(Unshadowed(base_colour_in, shadow_loss)+modern_diffuse, 0.0, 1.0);
		else if (kind>1.5)
			light=Unshadowed(light, shadow_loss);
		if (modern)
			debug_dynamic=modern_diffuse;
		debug_light=light;
		colour=Fog(light*texel.rgb, fog);
		fullbright_add=texel.rgb*texel.a;
	}
	vec3 specular=modern_specular*Gloss(texel.rgb);
	colour+=specular*fog;

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

	// debug views replace the colour; mostly transparent texels leave what's behind
	if (light_list.debug_view!=DEBUG_VIEW_NONE)
	{
		if (colour_out.a<0.5) discard;
		colour_out=DebugOutput(debug_light, debug_dynamic, normal, specular, shadow_loss, world_position_in, pc.directional.w);
	}
}
