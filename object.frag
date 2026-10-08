#version 450

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	vec4 light_scale_fullbright; // w: 1 if the bound texture is DTX_FULLBRITE
} pc;

layout(location=0) in vec4 colour_in;
layout(location=1) in vec2 uv_in; // normalised, like D3D TL vertices (model UVs are stored that way)

layout(location=0) out vec4 colour_out;

void main()
{
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_in);

	if (pc.light_scale_fullbright.w>0.5)
	{
		// fullbright textures: alpha marks the fullbright texels (palette 246..255), which d3d.ren draws again
		// with DECAL + alpha blending, i.e. at full texture colour (blood2_recon port_notes/model.md)
		colour_out=vec4(mix(colour_in.rgb*texel.rgb, texel.rgb, texel.a), colour_in.a);
	}
	else
	{
		// D3D MODULATEALPHA: colour and alpha both modulated by the texture
		colour_out=colour_in*texel;
	}
}
