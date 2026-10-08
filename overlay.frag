#version 450

// the engine's 2D layer: its 565 screen buffer (sampled as R5G6B5, expanded by the hardware) and a mask that is 1
// where 2D was drawn since the last clear
layout(set=0, binding=0) uniform sampler2D overlay;
layout(set=0, binding=1) uniform sampler2D overlay_mask;

layout(push_constant) uniform PushConstants {
	float opaque; // 1 without a 3D scene: the 2D layer is the whole frame, cleared areas black
} pc;

layout(location=0) in vec2 uv_in;

layout(location=0) out vec4 colour_out;

void main()
{
	float alpha=max(pc.opaque, texture(overlay_mask, uv_in).r>0.5 ? 1.0 : 0.0);
	colour_out=vec4(texture(overlay, uv_in).rgb, alpha);
}
