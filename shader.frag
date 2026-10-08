#version 450
#extension GL_ARB_separate_shader_objects: enable

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=0, binding=3) uniform texture2D lightmap_atlas;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	vec4 light_scale_fullbright; // xyz: SceneDesc GlobalLightScale, w: 1 if the bound texture is DTX_FULLBRITE
} pc;

layout(location=0) in vec3 colour_in;
layout(location=1) in vec2 uv_coord_in;
layout(location=2) in vec2 lightmap_uv_in;
layout(location=3) in float lightmapped_in;
layout(location=4) in vec3 dynamic_light_in;

layout(location=0) out vec4 colour_out;

// blood2_recon port_notes/world.md 4: lightmapped polies are LM * scale * texture (two-pass default), Gouraud polies
// texture * pre-lit colour * scale (+ dynamic lights); fullbright textures add texture * texture alpha
void main()
{
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_coord_in/textureSize(sampler2D(tex, tex_sampler), 0));

	vec3 base_light=(lightmapped_in>0.5) ? texture(sampler2D(lightmap_atlas, tex_sampler), lightmap_uv_in).rgb : colour_in;
	vec3 light=clamp(base_light*pc.light_scale_fullbright.xyz+dynamic_light_in, 0.0, 1.0);

	vec3 colour=texel.rgb*light;
	if (pc.light_scale_fullbright.w>0.5)
		colour+=texel.rgb*texel.a;

	colour_out=vec4(min(colour, vec3(1.0)), 1.0);
}
