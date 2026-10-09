#version 450

// Post-processing of the 3D scene (post_process.d), before the 2D layer goes on top.
// Anti-aliasing 1: FXAA, after Timothy Lottes' FXAA 3.11 "quality" variant at its preset 12 (luma edge detection, a
// 5-step search along the edge, blend across it), with green as luma and the neighbourhood read by two gathers like
// its FXAA_GATHER4 path, and less sub-pixel blending than its default so the low-resolution textures stay sharp.

layout(set=0, binding=0) uniform sampler2D scene;

layout(push_constant) uniform PushConstants {
	vec2 texel; // 1 / size
	float anti_aliasing; // 0 off, 1 FXAA
	float from_x; // the effects apply at and right of this x (d_Compare draws the left half without them)
} pc;

layout(location=0) in vec2 uv_in;

layout(location=0) out vec4 colour_out;

#define EDGE_THRESHOLD_MIN 0.0312
#define EDGE_THRESHOLD_MAX 0.125
#define SUBPIXEL_QUALITY 0.5
#define SEARCH_STEPS 5

const float search_step[SEARCH_STEPS]=float[](1.0, 1.5, 2.0, 4.0, 12.0);

float LumaAt(vec2 uv)
{
	return textureLod(scene, uv, 0.0).g;
}

vec3 Fxaa(vec2 uv)
{
	// the 3x3 neighbourhood's luma: a gather a quarter texel past the centre always covers the centre texel and the ones
	// right and below it, the other one the ones left and above (gather order: x (0,1), y (1,1), z (1,0), w (0,0))
	ivec2 pixel=ivec2(gl_FragCoord.xy);
	vec2 gather_uv=(vec2(pixel)+0.75)*pc.texel;
	vec4 luma_a=textureGather(scene, gather_uv, 1);
	vec4 luma_b=textureGatherOffset(scene, gather_uv, ivec2(-1, -1), 1);
	float centre=luma_a.w;
	float right=luma_a.z, down=luma_a.x, down_right=luma_a.y; // "down" is +y in the image
	float up_left=luma_b.w, up=luma_b.z, left=luma_b.x;

	vec3 centre_colour=texelFetch(scene, pixel, 0).rgb;
	float luma_min=min(centre, min(min(down, up), min(left, right)));
	float luma_max=max(centre, max(max(down, up), max(left, right)));
	float range=luma_max-luma_min;
	if (range<max(EDGE_THRESHOLD_MIN, luma_max*EDGE_THRESHOLD_MAX))
		return centre_colour;

	float up_right=texelFetchOffset(scene, pixel, 0, ivec2(1, -1)).g;
	float down_left=texelFetchOffset(scene, pixel, 0, ivec2(-1, 1)).g;

	float down_up=down+up;
	float left_right=left+right;
	float left_corners=down_left+up_left;
	float down_corners=down_left+down_right;
	float right_corners=down_right+up_right;
	float up_corners=up_right+up_left;

	// is the edge horizontal or vertical?
	float edge_horizontal=abs(-2.0*left+left_corners)+abs(-2.0*centre+down_up)*2.0+abs(-2.0*right+right_corners);
	float edge_vertical=abs(-2.0*up+up_corners)+abs(-2.0*centre+left_right)*2.0+abs(-2.0*down+down_corners);
	bool horizontal=edge_horizontal>=edge_vertical;

	// which side of the pixel the edge is on (side 1: up or left, towards -y / -x)
	float luma1=horizontal ? up : left;
	float luma2=horizontal ? down : right;
	float gradient1=luma1-centre;
	float gradient2=luma2-centre;
	bool side1=abs(gradient1)>=abs(gradient2);
	float gradient_scaled=0.25*max(abs(gradient1), abs(gradient2));

	float step_length=horizontal ? pc.texel.y : pc.texel.x;
	float local_average;
	if (side1)
	{
		step_length=-step_length;
		local_average=0.5*(luma1+centre);
	}
	else
		local_average=0.5*(luma2+centre);

	// onto the edge, then search along it both ways for its ends
	vec2 edge_uv=uv;
	if (horizontal)
		edge_uv.y+=step_length*0.5;
	else
		edge_uv.x+=step_length*0.5;

	vec2 offset=horizontal ? vec2(pc.texel.x, 0.0) : vec2(0.0, pc.texel.y);
	vec2 uv1=edge_uv-offset*search_step[0];
	vec2 uv2=edge_uv+offset*search_step[0];
	float end1=0.0, end2=0.0;
	bool reached1=false, reached2=false;
	for(int i=0; i<SEARCH_STEPS; ++i)
	{
		if (!reached1)
		{
			end1=LumaAt(uv1)-local_average;
			reached1=abs(end1)>=gradient_scaled;
			if (!reached1 && i+1<SEARCH_STEPS) uv1-=offset*search_step[i+1];
		}
		if (!reached2)
		{
			end2=LumaAt(uv2)-local_average;
			reached2=abs(end2)>=gradient_scaled;
			if (!reached2 && i+1<SEARCH_STEPS) uv2+=offset*search_step[i+1];
		}
		if (reached1 && reached2)
			break;
	}

	float distance1=horizontal ? uv.x-uv1.x : uv.y-uv1.y;
	float distance2=horizontal ? uv2.x-uv.x : uv2.y-uv.y;
	bool towards1=distance1<distance2;
	float nearest=min(distance1, distance2);
	float edge_length=distance1+distance2;

	// blend across the edge only if the luma changes the right way at the nearer end
	bool centre_smaller=centre<local_average;
	bool correct=((towards1 ? end1 : end2)<0.0)!=centre_smaller;
	float edge_offset=correct ? 0.5-nearest/edge_length : 0.0;

	// sub-pixel aliasing: thin features against the 3x3 average
	float average=(1.0/12.0)*(2.0*(down_up+left_right)+left_corners+right_corners);
	float subpixel=clamp(abs(average-centre)/range, 0.0, 1.0);
	subpixel=(-2.0*subpixel+3.0)*subpixel*subpixel;
	float final_offset=max(edge_offset, subpixel*subpixel*SUBPIXEL_QUALITY);

	vec2 final_uv=uv;
	if (horizontal)
		final_uv.y+=final_offset*step_length;
	else
		final_uv.x+=final_offset*step_length;
	return textureLod(scene, final_uv, 0.0).rgb;
}

void main()
{
	bool effects=gl_FragCoord.x>=pc.from_x;
	vec3 colour=(effects && pc.anti_aliasing>0.5) ? Fxaa(uv_in) : texelFetch(scene, ivec2(gl_FragCoord.xy), 0).rgb;
	colour_out=vec4(colour, 1.0);
}
