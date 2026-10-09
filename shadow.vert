#version 450

// a model drawn from a static lamp into its tile of the shadow atlas (static_lighting.d), depth only

layout(push_constant) uniform PushConstants {
	mat4 view_proj; // world -> the tile's clip space
} pc;

layout(location=0) in vec3 position_in; // ObjectVertex.pos, world space

void main()
{
	gl_Position=pc.view_proj*vec4(position_in, 1.0);
}
