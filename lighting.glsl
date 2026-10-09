// Dynamic lights, shared by the world (shader.*) and object (object.*) shaders.
//
// Classic: d3d.ren's formulas (blood2_recon port_notes/world.md 5.2, worldmodels.md), no N.L.
// Modern (d_Lighting 1): every light per pixel with N.L, a smooth falloff and Blinn-Phong specular, the same function
// for world polies, world models and models. Light colours keep d3d.ren's signed (2c - 1) form, so a light below half
// grey still darkens, as the levels were made for.

#define MAX_LIGHT_COUNT 40

#define LIGHT_DONT_LIGHT_BACKFACING 1u // FLAG_DONTLIGHTBACKFACING
#define LIGHT_ONLY_WORLD 2u // FLAG_ONLYLIGHTWORLD: not for models

struct LightObj
{
	vec3 position; float flags; // LIGHT_* bits
	vec3 colour; // 0..1
	float radius;
};

layout(set=0, binding=2) uniform LightList {
	uint count;
	float light_saturate; // console LightSaturate, for the classic per-texel lights
	float modern_from_x; // fragments at or right of this x use the modern lighting (-1: all, huge: none)
	float specular; // d_Specular, 0 = none
	vec4 camera; // xyz: eye position; w: falloff exponent (d_LightFalloff)
	vec4 model_light; // xyz: unit vector towards the models' fixed light; w: specular exponent
	uint debug_view; // DEBUG_VIEW_*: the frame shows one lighting term instead of the colour (debug captures)
	float effects_from_x; // the other modern effects (static lamp shadows) at and right of this x
	float debug_pad1, debug_pad2;
	LightObj lights[MAX_LIGHT_COUNT];
} light_list;

// d3d.ren's vertex lights (Gouraud polies, world models, the cloud pass): (2c - 1) * (1 - d/r) per light; a light with
// FLAG_DONTLIGHTBACKFACING skips polies it is behind (d3d.ren 0x241d0)
vec3 ClassicVertexLight(vec3 p, vec3 n, bool check_backfacing)
{
	vec3 light=vec3(0.0);
	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];
		if (check_backfacing && (uint(obj.flags) & LIGHT_DONT_LIGHT_BACKFACING)!=0u && dot(n, obj.position-p)<0.01)
			continue;
		float distance_to_light=distance(obj.position, p);
		if (distance_to_light>=obj.radius) continue;
		light+=(2.0*obj.colour-1.0)*(1.0-distance_to_light/obj.radius);
	}
	return light;
}

// d3d.ren rebuilds the lightmap of a lit poly every frame (d3d_BuildLightmap): per texel and light within the radius,
// k = trunc((1 - d^2/r^2) * 63) and I = min(1, LightSaturate * k / 63), and the texel gets I * (2c - 255) added. The
// falloff is quadratic, unlike the vertex lights. Evaluated per pixel here instead of on the lightmap's 20-unit grid.
vec3 ClassicTexelLight(vec3 p, vec3 n, bool check_backfacing)
{
	vec3 light=vec3(0.0);
	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];
		if (check_backfacing && (uint(obj.flags) & LIGHT_DONT_LIGHT_BACKFACING)!=0u && dot(n, obj.position-p)<0.01)
			continue;
		vec3 to_light=obj.position-p;
		float d2=dot(to_light, to_light), r2=obj.radius*obj.radius;
		if (d2>=r2) continue;
		float k=floor((1.0-d2/r2)*63.0);
		light+=(2.0*obj.colour-1.0)*min(1.0, light_list.light_saturate*k/63.0);
	}
	return light;
}

#ifdef FRAGMENT_SHADER
bool Modern()
{
	return gl_FragCoord.x>=light_list.modern_from_x;
}

// The level's static lamps (static_lighting.d): per model the lamps that light it, and the shadow pairs, each a lamp
// and a model drawn from it into a tile of the shadow atlas. Lamp terms are in lightmap units: the bake was ambient +
// colour * BrightScale * (1 - d/r) * cone, one-sided.
struct StaticLamp
{
	vec4 pos_radius;
	vec4 colour_index; // rgb: colour * BrightScale; w: the lamp's index in the level
	vec4 spot; // xyz: direction; w: cos of half the FOV, or -2 for a point lamp
};

struct ShadowPair
{
	mat4 view_proj; // world -> the tile's clip space
	StaticLamp lamp;
	vec4 tile; // xy: corner in the atlas, z: size; w: the caster (its index in the frame's model records)
};

struct ModelLamps
{
	vec4 residual_count; // rgb: the light grid's directional light the lamps don't account for; w: lamp count
	StaticLamp lamps[4];
};

layout(std430, set=0, binding=4) readonly buffer StaticLighting {
	uvec4 counts; // shadow pairs, model sets, 1 if shadows are on, 1 if models are lit by the lamps
	vec4 ambient; // rgb: the level's lightmap ambient; w: one shadow atlas texel
	ShadowPair pairs[64];
	ModelLamps models[128];
} static_lighting;

layout(set=0, binding=5) uniform sampler2DShadow shadow_atlas;

bool ShadowsOn()
{
	return static_lighting.counts.z!=0u && static_lighting.counts.x!=0u && gl_FragCoord.x>=light_list.effects_from_x;
}

// a lamp's contribution at p as the bake computed it (without the facing test)
vec3 LampAt(StaticLamp lamp, vec3 p)
{
	vec3 to=p-lamp.pos_radius.xyz;
	float d=length(to);
	if (d>=lamp.pos_radius.w)
		return vec3(0.0);
	float f=1.0-d/lamp.pos_radius.w;
	if (lamp.spot.w>-1.5)
	{
		float c=d>0.001 ? dot(lamp.spot.xyz, to)/d : 1.0;
		f*=max((c-lamp.spot.w)/(1.0-lamp.spot.w), 0.0);
	}
	return lamp.colour_index.rgb*f;
}

// how much pair k's model hides its lamp at p: 0 lit .. 1 shadowed. Nine bilinear depth-compare taps on a disk two
// texels across (each tap already blends 2x2 texels), for soft edges rather than the tile's stair steps.
const vec2 shadow_taps[9]=vec2[](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
	vec2(0.7, 0.7), vec2(-0.7, 0.7), vec2(0.7, -0.7), vec2(-0.7, -0.7));

float PairShadow(uint k, vec3 p)
{
	vec4 clip=static_lighting.pairs[k].view_proj*vec4(p, 1.0);
	if (clip.w<=0.001)
		return 0.0;
	vec3 ndc=clip.xyz/clip.w;
	if (abs(ndc.x)>=1.0 || abs(ndc.y)>=1.0 || ndc.z<=0.0 || ndc.z>=1.0)
		return 0.0;
	vec4 tile=static_lighting.pairs[k].tile;
	float texel=static_lighting.ambient.w;
	vec2 uv=tile.xy+(ndc.xy*0.5+0.5)*tile.z;
	vec2 low=tile.xy+vec2(2.5*texel), high=tile.xy+vec2(tile.z-2.5*texel);
	float depth=ndc.z-0.0002;
	float lit=0.0;
	for(int i=0; i<9; ++i)
		lit+=texture(shadow_atlas, vec3(clamp(uv+shadow_taps[i]*2.0*texel, low, high), depth));
	return 1.0-lit/9.0;
}

// for the shadow debug view: (strongest raw pair shadow, 1 if any pair's frustum covers p)
vec2 ShadowCoverage(vec3 p)
{
	float strongest=0.0, covered=0.0;
	for(uint k=0u; k<static_lighting.counts.x; ++k)
	{
		vec4 clip=static_lighting.pairs[k].view_proj*vec4(p, 1.0);
		if (clip.w<=0.001)
			continue;
		vec3 ndc=clip.xyz/clip.w;
		if (abs(ndc.x)<1.0 && abs(ndc.y)<1.0 && ndc.z>0.0 && ndc.z<1.0)
			covered=1.0;
		strongest=max(strongest, PairShadow(k, p));
	}
	return vec2(strongest, covered);
}

// The static light a world surface (normal n) loses at p where models hide lamps from it. `baked` is the surface's baked
// light there (lightmap or pre-lit colour): a pair only takes away light the bake shows arrived, so where the bake
// already had the lamp blocked (a closed door's own baked shadow, say) nothing is taken twice. `caster`: the surface's
// own model record (world models don't shadow themselves), -1 for the world.
vec3 WorldShadowLoss(vec3 p, vec3 n, vec3 baked, int caster)
{
	vec3 loss=vec3(0.0);
	float received=dot(max(baked-static_lighting.ambient.rgb, vec3(0.0)), vec3(0.299, 0.587, 0.114));
	for(uint k=0u; k<static_lighting.counts.x; ++k)
	{
		if (int(static_lighting.pairs[k].tile.w)==caster)
			continue;
		StaticLamp lamp=static_lighting.pairs[k].lamp;
		vec3 to_lamp=lamp.pos_radius.xyz-p;
		if (dot(to_lamp, to_lamp)>=lamp.pos_radius.w*lamp.pos_radius.w || dot(n, to_lamp)<=0.0)
			continue;
		vec3 c=LampAt(lamp, p);
		float expected=dot(c, vec3(0.299, 0.587, 0.114));
		if (expected<=0.0)
			continue;
		float s=PairShadow(k, p);
		if (s>0.0)
			loss+=s*c*smoothstep(0.25, 0.75, received/expected);
	}
	return loss;
}

// a baked light term (lightmap or pre-lit colour) with the shadowed lamps taken out; never below the level's ambient
vec3 Unshadowed(vec3 baked, vec3 loss)
{
	return baked-min(loss, max(baked-static_lighting.ambient.rgb, vec3(0.0)));
}

// how much other models hide one of this model's lamps at p (caster: this model's record)
float ModelLampShadow(StaticLamp lamp, int caster, vec3 p)
{
	float shadow=0.0;
	for(uint k=0u; k<static_lighting.counts.x; ++k)
		if (static_lighting.pairs[k].lamp.colour_index.w==lamp.colour_index.w && int(static_lighting.pairs[k].tile.w)!=caster)
			shadow=max(shadow, PairShadow(k, p));
	return shadow;
}
#endif

// Modern per-pixel lights at p with unit normal n: diffuse is signed like the classic lights, specular only from the
// positive part of the colour. Falloff (1 - d^2/r^2)^e, e = d_LightFalloff (1: d3d.ren's lightmap curve, unquantised).
void ModernLights(vec3 p, vec3 n, bool for_models, inout vec3 diffuse, inout vec3 specular)
{
	vec3 to_eye=normalize(light_list.camera.xyz-p);
	for(uint i=0; i<light_list.count; ++i)
	{
		LightObj obj=light_list.lights[i];
		if (for_models && (uint(obj.flags) & LIGHT_ONLY_WORLD)!=0u)
			continue;
		vec3 to_light=obj.position-p;
		float d2=dot(to_light, to_light), r2=obj.radius*obj.radius;
		if (d2>=r2) continue;

		vec3 l=to_light*inversesqrt(max(d2, 1e-6));
		float n_dot_l=dot(n, l);
		if (n_dot_l<=0.0) continue;

		float attenuation=pow(1.0-d2/r2, light_list.camera.w)*n_dot_l;
		vec3 colour=2.0*obj.colour-1.0;
		diffuse+=colour*attenuation;
		if (light_list.specular>0.0)
		{
			vec3 h=normalize(l+to_eye);
			specular+=max(colour, vec3(0.0))*attenuation*pow(max(dot(n, h), 0.0), light_list.model_light.w);
		}
	}
}

// How much specular a texel takes, from the only material hint there is: brighter texels are shinier. Kept low; d_Specular
// scales it.
float Gloss(vec3 texel)
{
	return light_list.specular*dot(texel, vec3(0.299, 0.587, 0.114));
}

// Debug captures (debug_capture.d) draw the frame again with one term per view instead of the colour, read back
// losslessly; each encoding below is decoded by tools/analyze_capture.py.
#define DEBUG_VIEW_NONE 0u
#define DEBUG_VIEW_LIGHT 1u // the light the texel is multiplied by, 0..1 (as used, after clamping)
#define DEBUG_VIEW_DYNAMIC 2u // the dynamic lights' part of it, signed: byte = 128 + d * 63.75 (0 exactly at 128)
#define DEBUG_VIEW_NORMAL 3u // world-space normal * 0.5 + 0.5; 0.5 grey where none
#define DEBUG_VIEW_ID 4u // which draw made the pixel: rgb = 24-bit id (debug_capture.d's id table)
#define DEBUG_VIEW_SPECULAR 5u // the specular added on top
#define DEBUG_VIEW_LIGHTS 6u // r = lights in range / 40, g = of those, lights facing the surface / 40
#define DEBUG_VIEW_SHADOW 7u // r: the static light taken away by the lamp shadows; g: the strongest raw shadow of any pair
                             // at the pixel; b: 1 where any pair's frustum covers the pixel

vec4 DebugOutput(vec3 light, vec3 dynamic, vec3 normal, vec3 specular, vec3 shadow, vec3 p, float id)
{
	uint view=light_list.debug_view;
#ifdef FRAGMENT_SHADER
	if (view==DEBUG_VIEW_SHADOW)
		return vec4(clamp(dot(shadow, vec3(0.299, 0.587, 0.114)), 0.0, 1.0), ShadowCoverage(p), 1.0);
#endif
	if (view==DEBUG_VIEW_LIGHT)
		return vec4(clamp(light, 0.0, 1.0), 1.0);
	if (view==DEBUG_VIEW_DYNAMIC)
		return vec4(clamp((128.0+round(dynamic*63.75))/255.0, 0.0, 1.0), 1.0);
	if (view==DEBUG_VIEW_NORMAL)
		return vec4(normal*0.5+0.5, 1.0);
	if (view==DEBUG_VIEW_ID)
	{
		uint i=uint(id+0.5);
		return vec4(float(i & 255u), float((i >> 8) & 255u), float((i >> 16) & 255u), 255.0)/255.0;
	}
	if (view==DEBUG_VIEW_SPECULAR)
		return vec4(clamp(specular, 0.0, 1.0), 1.0);
	// DEBUG_VIEW_LIGHTS
	float in_range=0.0, facing=0.0;
	for(uint i=0; i<light_list.count; ++i)
	{
		vec3 to_light=light_list.lights[i].position-p;
		if (dot(to_light, to_light)>=light_list.lights[i].radius*light_list.lights[i].radius) continue;
		in_range+=1.0;
		if (dot(normal, to_light)>0.0) facing+=1.0;
	}
	return vec4(in_range/40.0, facing/40.0, 0.0, 1.0);
}
