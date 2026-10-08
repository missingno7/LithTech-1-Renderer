module WorldModelDraw;

/+
 + World models (doors, lifts, signs, ...) and containers, after blood2_recon docs/seed_pass/port_notes/worldmodels.md:
 + the original BSP's polygons drawn through the engine-built local -> world transform, coloured by their pre-lit
 + vertex colours scaled by GlobalLightScale. Translucent iff the first surface of the current BSP has flag 0x8; then
 + the object's alpha applies, otherwise they are opaque.
 +
 + Not ported yet: lightmaps on solid world models (they're lightmapped like the world), dynamic lights.
 +/

import LTObjects;
import SceneGeometry;
import RendererTypes: SceneDesc;
import Texture: SharedTexture, RenderTexture;
import WorldBsp: WorldBsp, WorldData, Polygon, SurfaceFlags;

enum : size_t
{
	WorldModelDataOffset=0x128, // WorldData*: current BSP, original BSP
	WorldModelTransformOffset=0x12c, // local -> world, row-major with column vectors
}

void DrawWorldModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene,
	scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	WorldData* data=At!(WorldData*)(object, WorldModelDataOffset);
	if (data is null)
		return;

	WorldBsp* current=data.objs[0];
	WorldBsp* original=data.objs[1] ? data.objs[1] : current;
	if (current is null || current.polygon_count==0 || current.polygons is null || original.polygons is null)
		return;

	const Mat4 transform=At!Mat4(object, WorldModelTransformOffset);

	Polygon* first=current.polygons[0];
	const bool translucent=first && first.surface && (first.surface.flags & SurfaceFlags.Transparent);
	const float alpha=translucent ? object.a/255f : 1f;
	const float[3] scale=scene.global_light_scale.vector;

	RenderTexture batch_texture;
	bool batch_open=false;

	foreach(polygon; original.polygons[0..original.polygon_count])
	{
		if (polygon is null || polygon.surface is null || (polygon.surface.flags & SurfaceFlags.Invisible))
			continue;

		auto vertices=polygon.DiskVerts();
		if (vertices.length<3)
			continue;

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
			ObjectVertex vertex={
				pos: transform.TransformPoint([source.vertex_data.x, source.vertex_data.y, source.vertex_data.z]),
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

	if (batch_open)
		geometry.End();
}
