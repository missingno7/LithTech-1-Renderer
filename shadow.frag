#version 450

// depth only; masked world models (bars, grates) leave their see-through texels out, so light passes the gaps

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	mat4 view_proj;
	vec4 mode; // x: 1 = alpha-test the texture
} pc;

layout(location=0) in vec2 uv_in;
layout(location=1) in float alpha_in;

void main()
{
	if (pc.mode.x>0.5 && texture(sampler2D(tex, tex_sampler), uv_in).a*alpha_in<0.5)
		discard;
}
