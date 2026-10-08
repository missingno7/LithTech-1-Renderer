#version 450

layout(set=0, binding=0) uniform sampler2D overlay;

layout(location=0) in vec2 uv_in;

layout(location=0) out vec4 colour_out;

void main()
{
	colour_out=texture(overlay, uv_in);
}
