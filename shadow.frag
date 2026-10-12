#version 450

// depth only; masked world models (bars, grates) leave their see-through texels out, so light passes the gaps

layout(set=0, binding=1) uniform sampler tex_sampler;
layout(set=1, binding=0) uniform texture2D tex;

layout(push_constant) uniform PushConstants {
	mat4 view_proj;
	vec4 mode; // x: 1 = alpha-test the texture
	vec4 light_eye; // xyz point light position; mode.z: inverse radius (0 for a static lamp)
} pc;

layout(location=0) in vec2 uv_in;
layout(location=1) in float alpha_in;
layout(location=2) in vec3 world_in;

void main()
{
	if (pc.mode.x>0.5 && texture(sampler2D(tex, tex_sampler), pc.mode.y>0.5 ? uv_in/textureSize(sampler2D(tex, tex_sampler), 0) : uv_in).a*(pc.mode.y>0.5 ? 1.0 : alpha_in)<0.5)
		discard;
	// Radial point-light depth uses D16 precision uniformly across the entire light radius.
	// Static lamp tiles retain their existing perspective depth convention.
	gl_FragDepth=pc.mode.z>0.0 ? length(world_in-pc.light_eye.xyz)*pc.mode.z : gl_FragCoord.z;
}
