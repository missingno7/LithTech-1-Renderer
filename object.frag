#version 450

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=1, binding=0) uniform texture2D tex;

layout(location=0) in vec4 colour_in;
layout(location=1) in vec2 uv_in; // normalised, like D3D TL vertices (model UVs are stored that way)

layout(location=0) out vec4 colour_out;

void main()
{
	// D3D MODULATEALPHA: colour and alpha both modulated by the texture
	vec4 texel=texture(sampler2D(tex, tex_sampler), uv_in);
	colour_out=colour_in*texel;
}
