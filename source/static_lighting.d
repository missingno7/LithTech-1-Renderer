module StaticLighting;

/+
 + The level's static lights (the editor's Light / DirLight objects the lightmaps were baked from, read by world_file.d)
 + used at run time: models are lit from the actual lamps around them, and models cast shadows from those lamps.
 +
 + The bake, fitted against the lightmaps of two levels (doc/modernisation.md, tools/lighting_fit.py):
 +   lightmap = level ambient + Σ colour × BrightScale × (1 − d/r) × cone, on surfaces facing the lamp, occluded by
 +   geometry; cone = 1 for point lamps, (cos θ − cos h) / (1 − cos h) for spots (h half the FOV).
 + So where a model blocks a lamp, the world loses exactly that lamp's term: the shaders subtract it (lighting.glsl).
 +
 + Per frame, for every model: the lamps that reach its centre are ranked by their contribution there, the strongest are
 + traced through the world BSP (a lamp behind a wall doesn't count), and up to LampsPerModel of them light it. The
 + light grid's directional light the original used stays as a residual (whatever the chosen lamps don't account for),
 + and the lamps are scaled down where they'd add up to more than the grid at the model's centre: models get direction
 + and shadows from the lamps but not more light than the original gave them.
 + The strongest lamp/model pairs, favouring models near the camera, get a shadow map: a perspective view from the lamp
 + fitted around the model, one tile of the shadow atlas each. Only models are drawn into it; the world's own shadows
 + are already in the lightmaps.
 +/

import WorldFile: StaticLight;
import LTObjects: Normalised, Dot, TraceSegment;
import WorldBsp: WorldBsp, Node;

enum uint LampsPerModel=4;
enum uint MaxShadowPairs=64;
enum uint MaxModelSets=128;
enum uint ShadowAtlasTiles=8; // per side: 64 tiles

// lighting.glsl StaticLamp (std430)
struct GpuLamp
{
	float[4] pos_radius;
	float[4] colour_index; // rgb: colour × BrightScale, 0..1 (bake units); w: the lamp's index in the level
	float[4] spot; // xyz: direction; w: cos of half the FOV, or -2 for a point lamp
}

// lighting.glsl ShadowPair
struct GpuShadowPair
{
	float[16] view_proj; // world -> the tile's clip space, column-major
	GpuLamp lamp;
	float[4] tile; // xy: the tile's corner in the atlas (0..1), z: its size; w: the caster (its ModelRecord index)
}

// lighting.glsl ModelLamps
struct GpuModelSet
{
	float[4] residual_count; // rgb: the light grid's directional light the lamps don't cover; w: lamp count
	GpuLamp[LampsPerModel] lamps;
}

// lighting.glsl StaticLighting (std430 storage buffer)
struct GpuStaticLighting
{
	uint[4] counts; // shadow pairs, model sets, 1 if the shadows are on, 1 if models are lit by the lamps
	float[4] ambient; // rgb: the level's lightmap ambient; w: atlas texel size (1 / size)
	GpuShadowPair[MaxShadowPairs] pairs;
	GpuModelSet[MaxModelSets] models;
}
static assert(GpuLamp.sizeof==48 && GpuShadowPair.sizeof==128 && GpuModelSet.sizeof==208);

// a level lamp, prepared
struct Lamp
{
	float[3] pos;
	float radius;
	float[3] colour; // colour × BrightScale / 255
	float[3] direction=[0f, 0f, 1f];
	float cos_half=-2f; // spots; -2: a point lamp
	bool clip, light_objects;
	uint index;

	// its contribution at p in bake units (no facing test: models aren't one-sided)
	float[3] At(const float[3] p) const
	{
		import std.math: sqrt;
		const float[3] to=[p[0]-pos[0], p[1]-pos[1], p[2]-pos[2]];
		const float d=sqrt(Dot(to, to));
		if (d>=radius)
			return [0f, 0f, 0f];
		float f=1f-d/radius;
		if (cos_half>-1.5f)
		{
			const float c=d>0.001f ? Dot(direction, to)/d : 1f;
			const float cone=(c-cos_half)/(1f-cos_half);
			if (cone<=0f)
				return [0f, 0f, 0f];
			f*=cone;
		}
		return [colour[0]*f, colour[1]*f, colour[2]*f];
	}

	GpuLamp Gpu() const
	{
		return GpuLamp([pos[0], pos[1], pos[2], radius], [colour[0], colour[1], colour[2], cast(float)index],
			[direction[0], direction[1], direction[2], cos_half]);
	}
}

Lamp[] PrepareLamps(const StaticLight[] lights)
{
	import std.math: sin, cos, PI;
	Lamp[] lamps;
	foreach(i, ref light; lights)
	{
		if (light.kind!=StaticLight.Kind.Point && light.kind!=StaticLight.Kind.Spot && light.kind!=StaticLight.Kind.ObjectOnly)
			continue;
		Lamp lamp;
		lamp.pos=light.pos;
		lamp.radius=light.radius>1f ? light.radius : 1f;
		foreach(c; 0..3)
			lamp.colour[c]=light.colour[c]*light.bright_scale/255f;
		if (light.kind==StaticLight.Kind.Spot)
		{
			// Euler angles as the engine reads them: forward.y = -sin(pitch) (fitted against the lightmaps)
			const float pitch=light.rotation[0], yaw=light.rotation[1];
			lamp.direction=[sin(yaw)*cos(pitch), -sin(pitch), cos(yaw)*cos(pitch)];
			const float half=light.fov*0.5f*cast(float)PI/180f;
			lamp.cos_half=half>=cast(float)PI ? -1f : cos(half);
		}
		lamp.clip=light.clip;
		// ObjectLights light only models; plain lamps light models unless LightObjects is off
		lamp.light_objects=light.light_objects || light.kind==StaticLight.Kind.ObjectOnly;
		lamp.index=cast(uint)i;
		// a lamp that can't light models doesn't matter here
		if (lamp.light_objects)
			lamps~=lamp;
	}
	return lamps;
}

// what the renderer knows about a drawn model
struct ModelRecord
{
	void* object;
	float[3] centre;
	float radius;
	float[3] directional; // the light grid's directional light (0..1) the modern lighting uses
	bool solid; // casts shadows
	bool world_model; // a door, crate, masked wall...: casts shadows, isn't lit by the lamps (it's lightmapped)
}

// a shadow map to draw this frame
struct ShadowPairDraw
{
	uint model; // index into the frame's ModelRecords
	float[16] view_proj;
	uint tile;
}

struct SelectionSettings
{
	float[3] camera;
	uint max_pairs; // 0: no shadows
	bool light_models;
	WorldBsp* bsp;
}

// fills the GPU data and the shadow pairs for this frame's models
void SelectLamps(const Lamp[] lamps, const ModelRecord[] models, ref SelectionSettings settings,
	ref GpuStaticLighting gpu, ref ShadowPairDraw[] draws, ref int[] model_sets)
{
	import std.math: sqrt, asin, tan;
	import std.algorithm: sort, min;

	draws.length=0;
	model_sets.length=models.length;
	model_sets[]=-1;
	gpu.counts[0]=0;
	gpu.counts[1]=0;

	struct Candidate { uint lamp; float strength; float[3] contribution; }
	struct PairCandidate { uint model; uint lamp; float score; }
	PairCandidate[] pair_candidates;
	Candidate[] candidates;

	static float Luminance(const float[3] c) { return c[0]*0.299f+c[1]*0.587f+c[2]*0.114f; }

	foreach(m, ref model; models)
	{
		// ranked by the lamp's light at the near side of the model's bounding sphere (doors and walls are big)
		candidates.length=0;
		foreach(l, ref lamp; lamps)
		{
			float[3] to_lamp=[lamp.pos[0]-model.centre[0], lamp.pos[1]-model.centre[1], lamp.pos[2]-model.centre[2]];
			const float distance=sqrt(Dot(to_lamp, to_lamp));
			if (distance>=lamp.radius+model.radius)
				continue;
			if (model.world_model)
			{
				// a world model's shadow shows only where the lamp still reaches past it: ranked by the lamp's light
				// at the far side of its bounding sphere (a lamp under a grate lights the grate but nothing beyond it)
				const float[3] far_point=distance>0.001f ? [model.centre[0]-to_lamp[0]/distance*model.radius,
					model.centre[1]-to_lamp[1]/distance*model.radius, model.centre[2]-to_lamp[2]/distance*model.radius] : model.centre;
				const float behind=Luminance(lamp.At(far_point));
				if (behind>0.004f)
					candidates~=Candidate(cast(uint)l, behind, lamp.At(model.centre));
				continue;
			}
			const float step=model.world_model ? min(model.radius, distance*0.9f) : 0f;
			const float[3] near_point=distance>0.001f ? [model.centre[0]+to_lamp[0]/distance*step,
				model.centre[1]+to_lamp[1]/distance*step, model.centre[2]+to_lamp[2]/distance*step] : model.centre;
			const float[3] c=lamp.At(near_point);
			const float strength=Luminance(c);
			if (strength>0.004f)
				candidates~=Candidate(cast(uint)l, strength, lamp.At(model.centre));
		}
		candidates.sort!((a, b) => a.strength>b.strength);

		const float[3] to_camera=[model.centre[0]-settings.camera[0], model.centre[1]-settings.camera[1],
			model.centre[2]-settings.camera[2]];
		const float camera_distance=sqrt(Dot(to_camera, to_camera))-model.radius;
		const float near=1f/(1f+(camera_distance>0f ? camera_distance : 0f)/400f);
		// tiny models (attachments, the player's own invisible bits at the eye) aren't worth a shadow
		const bool casts=model.solid && settings.max_pairs && model.radius>=8f;

		// world models: shadow casters only, from their two strongest visible lamps
		if (model.world_model)
		{
			uint pairs=0;
			foreach(ref candidate; candidates[0..min($, 6)])
			{
				if (pairs>=2 || !casts)
					break;
				const Lamp* lamp=&lamps[candidate.lamp];
				if (!lamp.clip || (settings.bsp && settings.bsp.root_node && WorldModelLampHidden(settings.bsp, model, lamp.pos)))
					continue;
				pair_candidates~=PairCandidate(cast(uint)m, candidate.lamp, candidate.strength*near);
				pairs++;
			}
			continue;
		}

		if (gpu.counts[1]>=MaxModelSets)
			continue;
		// the strongest ones the model can see (traced from the model: a lamp fixture may sit inside a wall)
		const uint set=gpu.counts[1]++;
		model_sets[m]=cast(int)set;
		GpuModelSet* gpu_set=&gpu.models[set];
		float[3] covered=[0f, 0f, 0f];
		uint count=0;
		foreach(ref candidate; candidates[0..min($, 8)])
		{
			if (count>=LampsPerModel)
				break;
			const Lamp* lamp=&lamps[candidate.lamp];
			if (settings.bsp && settings.bsp.root_node && LampHidden(settings.bsp, model.centre, lamp.pos))
				continue;
			gpu_set.lamps[count++]=lamp.Gpu();
			covered[]+=candidate.contribution[];
			if (casts && lamp.clip)
				pair_candidates~=PairCandidate(cast(uint)m, candidate.lamp, candidate.strength*near);
		}
		// no more light than the grid had at the centre (the grid was baked from the same lamps)
		const float grid=Luminance(model.directional), lamp_sum=Luminance(covered);
		const float scale=lamp_sum>grid ? grid/(lamp_sum>1e-4f ? lamp_sum : 1e-4f) : 1f;
		foreach(i; 0..count)
			gpu_set.lamps[i].colour_index[0..3]*=scale;
		foreach(c; 0..3)
		{
			const float residual=model.directional[c]-covered[c]*scale;
			gpu_set.residual_count[c]=residual>0f ? residual : 0f;
		}
		gpu_set.residual_count[3]=cast(float)count;
	}

	// the shadow budget goes to the strongest pairs near the camera
	pair_candidates.sort!((a, b) => a.score>b.score);
	foreach(ref candidate; pair_candidates)
	{
		if (draws.length>=settings.max_pairs || draws.length>=MaxShadowPairs)
			break;
		const ModelRecord* model=&models[candidate.model];
		const Lamp* lamp=&lamps[candidate.lamp];
		float[16] view_proj;
		if (!ShadowFrustum(lamp.pos, lamp.radius, model.centre, model.radius, view_proj))
			continue;
		const uint k=cast(uint)draws.length;
		GpuShadowPair* pair=&gpu.pairs[k];
		pair.view_proj=view_proj;
		pair.lamp=lamp.Gpu();
		pair.tile=[(k%ShadowAtlasTiles)/cast(float)ShadowAtlasTiles, (k/ShadowAtlasTiles)/cast(float)ShadowAtlasTiles,
			1f/ShadowAtlasTiles, cast(float)candidate.model];
		draws~=ShadowPairDraw(candidate.model, view_proj, k);
	}
	gpu.counts[0]=cast(uint)draws.length;
}

// is the lamp hidden from p by the world? (a hit close to the lamp is the fixture's own wall: not hidden)
bool LampHidden(WorldBsp* bsp, const float[3] p, const float[3] lamp)
{
	float[4] plane;
	Node* node;
	float[3] hit;
	if (!TraceSegment(cast(Node*)bsp.root_node, p, lamp, plane, node, hit))
		return false;
	const float[3] gap=[hit[0]-lamp[0], hit[1]-lamp[1], hit[2]-lamp[2]];
	return Dot(gap, gap)>24f*24f;
}

// a world model is big and often flush with the world (a grate in a ceiling hole, a door in its frame): hidden only
// when the lamp is hidden from its centre and from four points across its face, each nudged towards the lamp
bool WorldModelLampHidden(WorldBsp* bsp, ref const ModelRecord model, const float[3] lamp)
{
	import std.math: sqrt, abs;

	float[3] to_lamp=[lamp[0]-model.centre[0], lamp[1]-model.centre[1], lamp[2]-model.centre[2]];
	const float distance=sqrt(Dot(to_lamp, to_lamp));
	if (distance<0.001f)
		return false;
	to_lamp[]/=distance;
	const float[3] up_hint=abs(to_lamp[1])>0.95f ? [1f, 0f, 0f] : [0f, 1f, 0f];
	const float[3] right=Normalised(Cross(up_hint, to_lamp));
	const float[3] up=Cross(to_lamp, right);
	const float spread=model.radius*0.5f, nudge=2f;
	static immutable float[2][5] offsets=[[0f, 0f], [1f, 0f], [-1f, 0f], [0f, 1f], [0f, -1f]];
	foreach(ref o; offsets)
	{
		float[3] p;
		foreach(c; 0..3)
			p[c]=model.centre[c]+to_lamp[c]*nudge+(right[c]*o[0]+up[c]*o[1])*spread;
		if (!LampHidden(bsp, p, lamp))
			return false;
	}
	return true;
}

// A perspective view from the lamp fitted around the model's bounding sphere, out to the lamp's radius (receivers
// beyond it get no light from the lamp anyway). Depth 0..1 (Vulkan), w = distance along the view axis. False when the
// lamp is too close to (or inside) the model.
bool ShadowFrustum(const float[3] eye, float lamp_radius, const float[3] centre, float radius, out float[16] view_proj)
{
	import std.math: sqrt, asin, tan, abs;

	const float[3] to=[centre[0]-eye[0], centre[1]-eye[1], centre[2]-eye[2]];
	const float distance=sqrt(Dot(to, to));
	const float fit=radius*1.15f;
	if (distance<=fit*1.05f || distance>=lamp_radius+radius)
		return false;
	const float[3] forward=[to[0]/distance, to[1]/distance, to[2]/distance];
	const float[3] up_hint=abs(forward[1])>0.95f ? [1f, 0f, 0f] : [0f, 1f, 0f];
	const float[3] right=Normalised(Cross(up_hint, forward));
	const float[3] up=Cross(forward, right);

	float half=asin(fit/distance);
	if (half>1.3f)
		half=1.3f;
	const float s=1f/tan(half);
	const float near=distance-fit>1f ? distance-fit : 1f;
	float far=lamp_radius;
	if (far<near+1f)
		far=near+1f;

	// rows of P * V (row-major), then stored column-major
	float[4][4] m;
	const float[3][3] axes=[right, up, forward];
	foreach(row; 0..2)
	{
		foreach(c; 0..3)
			m[row][c]=axes[row][c]*s;
		m[row][3]=-Dot(axes[row], eye)*s;
	}
	const float a=far/(far-near), b=-far*near/(far-near);
	foreach(c; 0..3)
		m[2][c]=forward[c]*a;
	m[2][3]=-Dot(forward, eye)*a+b;
	foreach(c; 0..3)
		m[3][c]=forward[c];
	m[3][3]=-Dot(forward, eye);
	foreach(row; 0..4)
		foreach(c; 0..4)
			view_proj[c*4+row]=m[row][c];
	return true;
}

float[3] Cross(const float[3] a, const float[3] b)
{
	return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
}
