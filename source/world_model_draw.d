module WorldModelDraw;

/+
 + World models (doors, lifts, signs, ...) and containers, after blood2_recon docs/seed_pass/port_notes/worldmodels.md:
 + the original BSP's polygons drawn through the engine-built local -> world transform.
 + - Solid world models are drawn like the world: lightmapped polygons (surface flag 0x80) as LM x GlobalLightScale x
 +   texture, the others with their pre-lit vertex colours x GlobalLightScale plus the dynamic lights (added by
 +   object.vert / object.frag), and fullbright texels added on top.
 + - Translucent ones (first surface of the current BSP has flag 0x8) take one Gouraud-style pass with the object's
 +   alpha: no lightmaps, no fullbright pass.
 +
 + Sky world models (port_notes/sky.md) use the same polygons without lightmaps, walked back to front through the
 + original BSP from the sky camera, and are moved by `offset` from the sky box into view of the main camera.
 +/

import LTObjects;
import SceneGeometry;
import RendererTypes: SceneDesc;
import Texture: SharedTexture, RenderTexture;
import WorldBsp: WorldBsp, WorldData, Polygon, SurfaceFlags, Node;

enum : size_t
{
	WorldModelDataOffset=0x128, // WorldData*: current BSP, original BSP
	WorldModelTransformOffset=0x12c, // local -> world, row-major with column vectors
}

// where each lightmapped polygon's block sits in the renderer's lightmap atlas (texels, inside the padding) and the
// atlas' 1/width, 1/height; set when a level's world is loaded (main world and every world model's original BSP)
__gshared uint[2][Polygon*] g_LightmapOrigins;
__gshared float[2] g_LightmapAtlasScale=[1f, 1f];

void DrawWorldModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene,
	scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	WorldModelPolygons emitter;
	if (!emitter.Setup(object, scene, [0f, 0f, 0f], false))
		return;

	// the dynamic lights are added on the GPU, from the frame's light list
	geometry.lighting=BatchLighting(LightingKind.WorldPolies);
	scope(exit) geometry.lighting=BatchLighting.init;

	foreach(polygon; emitter.original.polygons[0..emitter.original.polygon_count])
		emitter.Emit(geometry, polygon, resolve_texture);

	emitter.Finish(geometry);
}

// d3d.ren sky-object pass (0x1b9c0): the original BSP back to front from the sky camera, skipping invisible surfaces
void DrawSkyWorldModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene, const float[3] sky_camera,
	const float[3] offset, scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	WorldModelPolygons emitter;
	if (!emitter.Setup(object, scene, offset, true))
		return;

	Node*[500] pending; // the native walk's fixed stack
	size_t count=0;
	Node* node=emitter.original.root_node;
	while (node !is null)
	{
		if (node.flags & 3) // NODE_IN / NODE_OUT
		{
			if (count==0)
				break;
			node=pending[--count];
			continue;
		}
		if (node.planes is null)
			break;

		const float distance=node.planes.vector.x*sky_camera[0]+node.planes.vector.y*sky_camera[1]+
			node.planes.vector.z*sky_camera[2]-node.planes.distance;
		const int side=distance>0f;

		Polygon* polygon=node.polygons;
		if (side && polygon && polygon.surface && !(polygon.surface.flags & SurfaceFlags.Invisible))
			emitter.Emit(geometry, polygon, resolve_texture);

		if (count<pending.length)
			pending[count++]=node.next[side];
		node=node.next[!side];
	}

	emitter.Finish(geometry);
}

private struct WorldModelPolygons
{
	WorldBsp* original;
	Mat4 transform;
	bool translucent;
	bool sky; // no lightmaps, no fullbright pass, no dynamic lights
	float alpha;
	float[3] scale;
	float[3] offset;

	RenderTexture batch_texture;
	TextureMode batch_mode;
	bool batch_open;

	bool Setup(LTObject* object, SceneDesc* scene, const float[3] offset_, bool sky_)
	{
		WorldData* data=At!(WorldData*)(object, WorldModelDataOffset);
		if (data is null)
			return false;

		WorldBsp* current=data.objs[0];
		original=data.objs[1] ? data.objs[1] : current;
		if (current is null || current.polygon_count==0 || current.polygons is null || original is null || original.polygons is null)
			return false;

		transform=At!Mat4(object, WorldModelTransformOffset);

		Polygon* first=current.polygons[0];
		translucent=first && first.surface && (first.surface.flags & SurfaceFlags.Transparent);
		alpha=translucent ? object.a/255f : 1f;
		scale=scene.global_light_scale.vector;
		offset=offset_;
		sky=sky_;
		return true;
	}

	void Emit(ref ObjectGeometry geometry, Polygon* polygon, scope RenderTexture delegate(SharedTexture*) resolve_texture)
	{
		if (polygon is null || polygon.surface is null || (polygon.surface.flags & SurfaceFlags.Invisible))
			return;

		auto vertices=polygon.DiskVerts();
		if (vertices.length<3)
			return;

		RenderTexture texture=resolve_texture(polygon.surface.shared_texture);

		// the world's per-poly dispatch: solid world models only (translucent and sky ones are one Gouraud pass)
		const bool world_path=!translucent && !sky;
		const uint[2]* lightmap_origin=(world_path && (polygon.surface.flags & SurfaceFlags.LightMap)) ?
			(polygon in g_LightmapOrigins) : null;
		// a fullbright texture's alpha marks its fullbright texels, never opacity
		const TextureMode mode=!(texture && texture.fullbright) ? TextureMode.Normal :
			world_path ? TextureMode.WorldFullbright : TextureMode.Fullbright;

		if (!batch_open || texture !is batch_texture || mode!=batch_mode)
		{
			if (batch_open)
				geometry.End();
			geometry.Begin(texture ? texture.texture_descriptor : typeof(texture.texture_descriptor).init,
				translucent ? geometry.translucent_group : geometry.solid_group,
				translucent ? geometry.translucent_pipe : geometry.solid_pipe, mode);
			batch_texture=texture;
			batch_mode=mode;
			batch_open=true;
		}

		// texel UVs, normalised with the texture's size like d3d.ren's per-texture UV scale
		const float u_scale=(texture && texture.width) ? 1f/texture.width : 1f/64;
		const float v_scale=(texture && texture.height) ? 1f/texture.height : 1f/64;

		// the plane's normal in world space, for the dynamic lights
		float[3] normal=[0f, 0f, 0f];
		if (!sky && polygon.surface.plane)
		{
			const auto plane=polygon.surface.plane.vector;
			normal=Normalised(transform.TransformVector([plane.x, plane.y, plane.z]), [0f, 0f, 0f]);
		}

		ObjectVertex Vertex(size_t i)
		{
			const auto source=&vertices[i];
			const float[3] world_pos=transform.TransformPoint([source.vertex_data.x, source.vertex_data.y, source.vertex_data.z]);

			ObjectVertex vertex;
			vertex.pos=[world_pos[0]+offset[0], world_pos[1]+offset[1], world_pos[2]+offset[2]];
			vertex.uv=[source.uv.x*u_scale, source.uv.y*v_scale];
			vertex.normal=normal;

			if (lightmap_origin)
			{
				// pass A's diffuse is GlobalLightScale; the lightmap is multiplied in by the shader
				vertex.colour=[scale[0], scale[1], scale[2], alpha];
				vertex.lightmap=[(source.lightmap_uv.x+(*lightmap_origin)[0])*g_LightmapAtlasScale[0],
					(source.lightmap_uv.y+(*lightmap_origin)[1])*g_LightmapAtlasScale[1], 1f];
			}
			else
			{
				// pre-lit colour is stored b, g, r, a; scaled. Outside the sky the vertex shader adds the dynamic lights and
				// clamps the sum, as d3d.ren did.
				const float[3] colour=[source.colour[2]*scale[0], source.colour[1]*scale[1], source.colour[0]*scale[2]];
				foreach(channel; 0..3)
				{
					const float c=colour[channel]/255f;
					vertex.colour[channel]=c<0f ? 0f : (c>1f && sky) ? 1f : c;
				}
				vertex.colour[3]=alpha;
			}
			return vertex;
		}

		// triangle fan
		foreach(i; 1..vertices.length-1)
		{
			ObjectVertex a=Vertex(0), b=Vertex(i), c=Vertex(i+1);
			geometry.Add(a);
			geometry.Add(b);
			geometry.Add(c);
		}
	}

	void Finish(ref ObjectGeometry geometry)
	{
		if (batch_open)
			geometry.End();
		batch_open=false;
	}
}
