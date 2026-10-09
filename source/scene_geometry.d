module SceneGeometry;

/+
 + Per-frame geometry of the scene's objects (models, world models, sprites, particles, polygrids, line systems and the
 + sky), built on the CPU during RenderScene in world space and drawn by SwapBuffers: the sky group before the world,
 + the other groups after it in d3d.ren's d3d_FlushObjectQueues order (blood2_recon renderer_port_abi.md section 5).
 +/

import erupted;
import StaticLighting: ModelRecord;

struct ObjectVertex
{
	float[3] pos; // world space
	float[4] colour; // 0..1, alpha included
	float[2] uv; // normalised (0..1 across the texture), as d3d.ren hands them to D3D
	float[3] lightmap=[0f, 0f, 0f]; // atlas u, v (normalised) and 1 if lightmapped (solid world models)
	float[3] normal=[0f, 0f, 0f]; // world space, unit length, for the per-pixel lighting of models and world models

	static VkVertexInputBindingDescription GetBindingDescription()
	{
		VkVertexInputBindingDescription description={
			binding: 0,
			stride: ObjectVertex.sizeof,
			inputRate: VK_VERTEX_INPUT_RATE_VERTEX
		};
		return description;
	}

	static VkVertexInputAttributeDescription[5] GetAttributeDescriptions()
	{
		return [
			VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32B32_SFLOAT, pos.offsetof),
			VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, colour.offsetof),
			VkVertexInputAttributeDescription(2, 0, VK_FORMAT_R32G32_SFLOAT, uv.offsetof),
			VkVertexInputAttributeDescription(3, 0, VK_FORMAT_R32G32B32_SFLOAT, lightmap.offsetof),
			VkVertexInputAttributeDescription(4, 0, VK_FORMAT_R32G32B32_SFLOAT, normal.offsetof)
		];
	}
}

// draw order; Sky is drawn before the world, the rest after it in this order. Nothing is depth sorted.
enum DrawGroup
{
	Sky,
	SolidModels,
	SolidWorldModels,
	SolidPolyGrids,
	TranslucentModels, // from here on d3d.ren has the translucent object states on (blend, no depth write)
	ParticleSystems,
	TranslucentPolyGrids,
	LineSystems,
	TranslucentWorldModels,
	Sprites,
	SpritesNoZ, // FLAG_SPRITE_NOZ: drawn last with the depth test off
	LightAdd, // the camera's light add: an additive full-view quad after everything (d3d_draw.cpp r_DrawLightAddPoly)
}

// the object pipelines (vulkan_renderer.d CreateObjectPipeline)
enum ObjectPipe
{
	Opaque, // depth test and write
	Blend, // SRCALPHA / INVSRCALPHA, depth test, no depth write
	BlendNoZ, // blended, no depth test or write (sky, no-Z sprites)
	OpaqueNoZ, // no blend, no depth (solid sky objects)
	Lines, // line list, blended, depth test, no depth write
	Additive, // ONE / ONE, no depth (the light-add poly)
	BlendDepthWrite, // blended with depth test and write (model shadows: overlapping faces darken once)
}

enum TextureMode : ubyte
{
	Normal,
	Fullbright, // texture alpha marks fullbright texels, drawn over the lit texel (models: DECAL pass)
	Untextured, // white texture
	WorldFullbright, // fullbright texels added on top (world surfaces: SRCALPHA / ONE or the lightmap pass's SRCALPHA / SRCCOLOR)
}

// how a batch is lit (object.vert / object.frag push constants)
enum LightingKind
{
	PreLit, // the vertex colour is the light: sprites, particles, sky objects, shadows, ...
	Model, // the vertex colour is d3d.ren's light ramp; the modern lighting uses the batch's ambient and directional
	WorldPolies, // world models: lightmapped, or pre-lit plus the dynamic lights per vertex (classic) or pixel (modern)
}

// the model terms for the modern lighting, 0..1: ambient without the dynamic lights, and the light grid's directional
// light (d3d.ren's light ramp before it's stepped)
struct BatchLighting
{
	LightingKind kind;
	float[3] ambient=[0f, 0f, 0f];
	float[3] directional=[0f, 0f, 0f];
}

struct ObjectBatch
{
	VkDescriptorSet texture; // VK_NULL_ND_HANDLE: the renderer's dummy texture
	uint first_vertex;
	uint vertex_count;
	TextureMode mode;
	ObjectPipe pipe;
	bool no_fog; // drawn with fog off whatever the group (model shadows)
	BatchLighting lighting;
	void* source; // the object that drew it (LTObject*), for debug captures; null for the light-add poly
	int model=-1; // index into ObjectGeometry.models for a model's own passes (static lamp lighting and shadows)
}

struct ObjectGeometry
{
	ObjectVertex[] vertices;
	ObjectBatch[][DrawGroup.max+1] groups;

	// where the solid / translucent batches of Begin(texture, translucent, fullbright) go; models and world models set
	// these before drawing (DrawModel / DrawWorldModel only know whether they're translucent)
	DrawGroup solid_group=DrawGroup.SolidModels, translucent_group=DrawGroup.TranslucentModels;
	ObjectPipe solid_pipe=ObjectPipe.Opaque, translucent_pipe=ObjectPipe.Blend;
	// how batches opened from now on are lit; models and world models set it while they draw
	BatchLighting lighting;
	void* source; // the object batches opened from now on belong to (debug captures)
	ModelRecord[] models; // the frame's models (static_lighting.d)
	int model_index=-1; // the model batches opened from now on belong to
	bool object_list; // drawing an object-list scene (the view weapon): its models cast no shadows

	void Clear()
	{
		vertices.length=0;
		vertices.assumeSafeAppend();
		models.length=0;
		models.assumeSafeAppend();
		model_index=-1;
		foreach(ref group; groups)
		{
			group.length=0;
			group.assumeSafeAppend();
		}
	}

	void Route(DrawGroup solid, ObjectPipe solid_pipe_, DrawGroup translucent, ObjectPipe translucent_pipe_)
	{
		solid_group=solid;
		solid_pipe=solid_pipe_;
		translucent_group=translucent;
		translucent_pipe=translucent_pipe_;
	}

	// opens a batch; vertices appended until the next Begin belong to it
	void Begin(VkDescriptorSet texture, bool is_translucent, bool fullbright=false)
	{
		Begin(texture, is_translucent ? translucent_group : solid_group, is_translucent ? translucent_pipe : solid_pipe,
			fullbright ? TextureMode.Fullbright : TextureMode.Normal);
	}

	void Begin(VkDescriptorSet texture, DrawGroup group, ObjectPipe pipe, TextureMode mode, bool no_fog=false)
	{
		ObjectBatch batch={ texture: texture, first_vertex: cast(uint)vertices.length, vertex_count: 0, mode: mode, pipe: pipe, no_fog: no_fog,
			lighting: lighting, source: source, model: model_index };
		groups[group]~=batch;
		_current=group;
	}

	void Add(const ref ObjectVertex vertex)
	{
		vertices~=vertex;
		groups[_current][$-1].vertex_count++;
	}

	// drops the current batch if nothing was added to it
	void End()
	{
		ObjectBatch[]* list=&groups[_current];
		if ((*list).length && (*list)[$-1].vertex_count==0)
			(*list).length--;
	}

private:
	DrawGroup _current;
}
