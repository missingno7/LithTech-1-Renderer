module WorldModelDraw;

/+
 + World models (doors, lifts, signs, ...) and containers, after blood2_recon docs/seed_pass/port_notes/worldmodels.md:
 + the original BSP's polygons drawn through the engine-built local -> world transform, coloured by their pre-lit
 + vertex colours scaled by GlobalLightScale. Translucent iff the first surface of the current BSP has flag 0x8; then
 + the object's alpha applies, otherwise they are opaque.
 +
 + Sky world models (port_notes/sky.md) use the same polygons, walked back to front through the original BSP from the
 + sky camera, and are moved by `offset` from the sky box into view of the main camera.
 +
 + Not ported yet: lightmaps on solid world models (they're lightmapped like the world), dynamic lights.
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

void DrawWorldModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene,
	scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	WorldModelPolygons emitter;
	if (!emitter.Setup(object, scene, [0f, 0f, 0f]))
		return;

	foreach(polygon; emitter.original.polygons[0..emitter.original.polygon_count])
		emitter.Emit(geometry, polygon, resolve_texture);

	emitter.Finish(geometry);
}

// d3d.ren sky-object pass (0x1b9c0): the original BSP back to front from the sky camera, skipping invisible surfaces
void DrawSkyWorldModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene, const float[3] sky_camera,
	const float[3] offset, scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	WorldModelPolygons emitter;
	if (!emitter.Setup(object, scene, offset))
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
	float alpha;
	float[3] scale;
	float[3] offset;

	RenderTexture batch_texture;
	bool batch_open;

	bool Setup(LTObject* object, SceneDesc* scene, const float[3] offset_)
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
		if (!batch_open || texture !is batch_texture)
		{
			if (batch_open)
				geometry.End();
			geometry.Begin(texture ? texture.texture_descriptor : typeof(texture.texture_descriptor).init, translucent,
				texture && texture.fullbright);
			batch_texture=texture;
			batch_open=true;
		}

		// texel UVs, normalised with the texture's size like d3d.ren's per-texture UV scale
		const float u_scale=(texture && texture.width) ? 1f/texture.width : 1f/64;
		const float v_scale=(texture && texture.height) ? 1f/texture.height : 1f/64;

		ObjectVertex Vertex(size_t i)
		{
			const auto source=&vertices[i];
			float[3] pos=transform.TransformPoint([source.vertex_data.x, source.vertex_data.y, source.vertex_data.z]);
			pos[]+=offset[];
			ObjectVertex vertex={
				pos: pos,
				// pre-lit colour is stored b, g, r, a
				colour: [source.colour[2]/255f*scale[0], source.colour[1]/255f*scale[1], source.colour[0]/255f*scale[2], alpha],
				uv: [source.uv.x*u_scale, source.uv.y*v_scale]
			};
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
