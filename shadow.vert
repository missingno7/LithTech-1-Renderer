#version 450

// a model or world model drawn from a static lamp into its tile of the shadow atlas (static_lighting.d)

layout(push_constant) uniform PushConstants {
	mat4 view_proj; // world -> the tile's clip space
	vec4 mode; // x: 1 = leave out see-through texels (masked world models)
} pc;

layout(location=0) in vec3 position_in; // ObjectVertex, world space
layout(location=1) in vec4 colour_in;
layout(location=2) in vec2 uv_in;

layout(location=0) out vec2 uv_out;
layout(location=1) out float alpha_out;

void main()
{
	gl_Position=pc.view_proj*vec4(position_in, 1.0);
	uv_out=uv_in;
	alpha_out=colour_in.a;
}
