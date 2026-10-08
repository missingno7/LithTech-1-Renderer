module EffectsDraw;

/+
 + Sprites, particle systems, polygrids and line systems, after blood2_recon docs/seed_pass/port_notes/sprite.md,
 + particles.md, polygrid.md and linesystem.md (layouts: renderer_port_abi.md 4.5 - 4.8).
 +
 + Everything is emitted in world space for the shared object pipelines. d3d.ren builds sprites and particles in its
 + camera space, whose x/y are pre-scaled by the FOV so the frustum is |x|, |y| < z; translated to world units:
 + - a billboard sprite's half extents are texture width/height x object scale,
 + - a particle's half size is 2 x its radius (half size in pixels = radius x FovXScale x view width / z).
 +
 + Not ported: CoolFog, the (no-op) particle shadow pass.
 +/

import LTObjects;
import SceneGeometry;
import RendererTypes: SceneDesc;
import Texture: SharedTexture, RenderTexture;
import WorldBsp: MainWorld;

// how an object is seen: the main camera, or the sky camera for sky objects
struct EffectView
{
	float[3] camera; // camera position in the objects' own space (the sky camera for sky objects)
	float[3] right, up, forward; // camera axes, world space
	float[3] offset; // added to emitted positions: moves sky objects from the sky box into the main view
	float tan_half_fov_x, tan_half_fov_y;
	float near_z, far_z;
	bool sky;

	MainWorld* world; // light grid
	const(DynamicLight)[] lights;
	float[3] light_scale; // SceneDesc GlobalLightScale
	RenderTexture delegate(SharedTexture*) resolve_texture;

	float Depth(const float[3] p) const
	{
		return (p[0]-camera[0])*forward[0]+(p[1]-camera[1])*forward[1]+(p[2]-camera[2])*forward[2];
	}

	float[3] Out(const float[3] p) const
	{
		return [p[0]+offset[0], p[1]+offset[1], p[2]+offset[2]];
	}
}

private float[3] Madd(const float[3] p, const float[3] axis, float scale)
{
	return [p[0]+axis[0]*scale, p[1]+axis[1]*scale, p[2]+axis[2]*scale];
}

private void EmitQuad(ref ObjectGeometry geometry, const ref ObjectVertex[4] corners)
{
	// fan 0,1,2 / 0,2,3; culling is off for objects
	static immutable size_t[6] order=[0, 1, 2, 0, 2, 3];
	foreach(i; order)
		geometry.Add(corners[i]);
}

private VkDescriptorSetOf Descriptor(RenderTexture texture)
{
	return texture ? texture.texture_descriptor : VkDescriptorSetOf.init;
}

private alias VkDescriptorSetOf=typeof(RenderTexture.init.texture_descriptor);

//// Sprites (sprite.md)

enum : size_t
{
	SpriteAnimationOffset=0x12c,
	SpriteFrameOffset=0x130, // -> { SharedTexture* }
	SpriteClipperPolyOffset=0x13c, // HPOLY: world model index << 16 (0xffff = main world) | node index; 0xffffffff = none
}

// drawsprite.cpp r_ClipSprite: the quad is clipped against the planes through each edge of the clipper polygon; nothing is
// drawn if the camera is behind the polygon or the handle doesn't resolve
private ObjectVertex[] ClipToPolygon(const ObjectVertex[] quad, uint handle, const ref EffectView view)
{
	import WorldBsp: WorldBsp, WorldData, Polygon, Node;
	import std.math: sqrt;

	MainWorld* world=cast(MainWorld*)view.world;
	if (world is null)
		return null;

	WorldBsp* bsp;
	if ((handle >> 16)==0xFFFF)
		bsp=world.world_bsp;
	else
	{
		if ((handle >> 16)>=world.world_model_count || world.world_models is null)
			return null;
		WorldData* data=world.world_models[handle >> 16];
		bsp=data ? data.objs[0] : null;
	}
	if (bsp is null || bsp.nodes is null || (handle & 0xFFFF)>=bsp.node_count)
		return null;

	Polygon* polygon=bsp.nodes[handle & 0xFFFF].polygons;
	if (polygon is null || polygon.surface is null || polygon.surface.plane is null)
		return null;

	const float[3] normal=polygon.surface.plane.vector.vector;
	if (Dot(normal, view.camera)-polygon.surface.plane.distance<=0.01f)
		return null;

	static ObjectVertex[] buffer_a, buffer_b; // reused
	buffer_a.length=0;
	buffer_a.assumeSafeAppend();
	buffer_a~=quad;

	auto points=polygon.DiskVerts();
	if (points.length<3)
		return null;

	foreach(i; 0..points.length)
	{
		const float[3] previous=(*points[i==0 ? points.length-1 : i-1].vertex_data).xyz.vector;
		const float[3] current=(*points[i].vertex_data).xyz.vector;

		// the plane through this edge, facing into the polygon
		const float[3] edge=[current[0]-previous[0], current[1]-previous[1], current[2]-previous[2]];
		float[3] plane=[edge[1]*normal[2]-edge[2]*normal[1], edge[2]*normal[0]-edge[0]*normal[2], edge[0]*normal[1]-edge[1]*normal[0]];
		const float length=sqrt(Dot(plane, plane));
		if (length<1e-6f)
			continue;
		plane[]/=length;
		const float plane_distance=Dot(plane, current);

		buffer_b.length=0;
		buffer_b.assumeSafeAppend();
		foreach(j; 0..buffer_a.length)
		{
			const ObjectVertex* a=&buffer_a[j==0 ? buffer_a.length-1 : j-1];
			const ObjectVertex* b=&buffer_a[j];
			const float da=Dot(plane, a.pos)-plane_distance, db=Dot(plane, b.pos)-plane_distance;
			if (da>0f)
				buffer_b~=*a;
			if ((da>0f)!=(db>0f))
			{
				const float t=-da/(db-da);
				ObjectVertex v;
				foreach(k; 0..3) v.pos[k]=a.pos[k]+(b.pos[k]-a.pos[k])*t;
				foreach(k; 0..4) v.colour[k]=a.colour[k]+(b.colour[k]-a.colour[k])*t;
				foreach(k; 0..2) v.uv[k]=a.uv[k]+(b.uv[k]-a.uv[k])*t;
				buffer_b~=v;
			}
		}
		if (buffer_b.length==0)
			return null;

		// buffer_b now holds the polygon clipped so far
		auto swap=buffer_a;
		buffer_a=buffer_b;
		buffer_b=swap;
	}

	return buffer_a;
}

void DrawSprite(ref ObjectGeometry geometry, LTObject* object, const ref EffectView view)
{
	void* animation=At!(void*)(object, SpriteAnimationOffset);
	SharedTexture** frame=At!(SharedTexture**)(object, SpriteFrameOffset);
	if (animation is null || frame is null || *frame is null)
		return;

	// d3d.ren skips the sprite when its texture doesn't bind
	RenderTexture texture=view.resolve_texture(*frame);
	if (texture is null || texture.width==0 || texture.height==0)
		return;

	const float width=texture.width, height=texture.height;
	// half-texel inset
	const float u_min=0.5f/width, v_min=0.5f/height, u_max=(width-0.5f)/width, v_max=(height-0.5f)/height;
	const float[4] colour=SpriteColour(object, view);

	const bool no_z=(object.flags & ObjectFlag.SpriteNoZ)!=0;
	const DrawGroup group=view.sky ? DrawGroup.Sky : (no_z ? DrawGroup.SpritesNoZ : DrawGroup.Sprites);
	const ObjectPipe pipe=(view.sky || no_z) ? ObjectPipe.BlendNoZ : ObjectPipe.Blend;

	ObjectVertex[4] corners;

	if (object.flags & ObjectFlag.RotateableSprite)
	{
		// a world-space quad of texture size through the object's matrix
		const Mat4 matrix=SetupTransformation(object.pos, object.rot, object.scale);
		const float[2][4] local=[[width, height], [-width, height], [-width, -height], [width, -height]];
		const float[2][4] uvs=[[u_min, v_min], [u_max, v_min], [u_max, v_max], [u_min, v_max]];
		foreach(i; 0..4)
		{
			corners[i].pos=matrix.TransformPoint([local[i][0], local[i][1], 0f]);
			corners[i].colour=colour;
			corners[i].uv=uvs[i];
		}

		// decals: clipped to the edges of the world polygon they're on
		const uint clipper=At!uint(object, SpriteClipperPolyOffset);
		if (clipper!=0xFFFFFFFF && clipper!=0)
		{
			ObjectVertex[] polygon=ClipToPolygon(corners[], clipper, view);
			if (polygon.length<3)
				return;

			geometry.Begin(Descriptor(texture), group, pipe, texture.fullbright ? TextureMode.Fullbright : TextureMode.Normal);
			foreach(i; 1..polygon.length-1)
			{
				ObjectVertex a=polygon[0], b=polygon[i], c=polygon[i+1];
				a.pos=view.Out(a.pos);
				b.pos=view.Out(b.pos);
				c.pos=view.Out(c.pos);
				geometry.Add(a);
				geometry.Add(b);
				geometry.Add(c);
			}
			geometry.End();
			return;
		}

		foreach(ref corner; corners)
			corner.pos=view.Out(corner.pos);
	}
	else
	{
		// billboard parallel to the image plane
		const float depth=view.Depth(object.pos);
		if (depth<=7f)
			return;

		float half_x=width*object.scale[0], half_y=height*object.scale[1];
		if (object.flags & ObjectFlag.GlowSprite)
		{
			float factor=(depth-10f)*(1f/490f);
			factor=factor<0f ? 0f : factor>1f ? 1f : factor;
			factor=1.9f*factor+0.1f;
			half_x*=factor;
			half_y*=factor;
		}

		float[3] centre=object.pos;
		float size_scale=1f;
		if (object.flags & ObjectFlag.SpriteBias)
		{
			// d3d.ren biases only the depth by -20 (not below the near plane); sliding the sprite towards the camera along
			// its view ray and shrinking it by the same ratio keeps its screen position and size
			float biased=depth-20f;
			if (biased<view.near_z)
				biased=view.near_z;
			size_scale=biased/depth;
			foreach(axis; 0..3)
				centre[axis]=view.camera[axis]+(object.pos[axis]-view.camera[axis])*size_scale;
		}
		half_x*=size_scale;
		half_y*=size_scale;

		const float[3] left_top=Madd(Madd(centre, view.right, -half_x), view.up, half_y);
		const float[3] right_top=Madd(Madd(centre, view.right, half_x), view.up, half_y);
		const float[3] right_bottom=Madd(Madd(centre, view.right, half_x), view.up, -half_y);
		const float[3] left_bottom=Madd(Madd(centre, view.right, -half_x), view.up, -half_y);

		corners[0]=ObjectVertex(view.Out(left_top), colour, [u_min, v_min]);
		corners[1]=ObjectVertex(view.Out(right_top), colour, [u_max, v_min]);
		corners[2]=ObjectVertex(view.Out(right_bottom), colour, [u_max, v_max]);
		corners[3]=ObjectVertex(view.Out(left_bottom), colour, [u_min, v_max]);
	}

	geometry.Begin(Descriptor(texture), group, pipe, texture.fullbright ? TextureMode.Fullbright : TextureMode.Normal);
	EmitQuad(geometry, corners);
	geometry.End();
}

// d3d.ren 0x2e4c0: lit sprites add the light grid and the dynamic lights to the scaled object colour (additive, not
// modulated); FLAG_NOLIGHT gives the scaled object colour
private float[4] SpriteColour(LTObject* object, const ref EffectView view)
{
	const float[3] base=[object.r*view.light_scale[0], object.g*view.light_scale[1], object.b*view.light_scale[2]];
	float[3] c=base;

	if (!(object.flags & ObjectFlag.NoLight))
	{
		const float[3] grid=view.world ? SampleLightGrid(cast(MainWorld*)view.world, object.pos) : [0f, 0f, 0f];
		const float[3] add=CalcLightAdd(object.pos, view.lights);
		foreach(channel; 0..3)
		{
			c[channel]=base[channel]+grid[channel]+add[channel];
			c[channel]=c[channel]<0f ? 0f : c[channel]>255f ? 255f : c[channel];
		}
	}

	return [c[0]/255f, c[1]/255f, c[2]/255f, object.a/255f];
}

//// Particle systems (particles.md)

enum : size_t
{
	ParticleHeadOffset=0x128, // embedded PSParticle head
	ParticleFirstOffset=0x140, // the head's next
	ParticleTextureOffset=0x15c,
	ParticleCountOffset=0x19c,
	ParticleRadiusOffset=0x1c0,

	PSParticleColourOffset=0x0c, // floats 0..255
	PSParticleNextOffset=0x18,
	PSParticlePosOffset=0x1c, // system-local
}

void DrawParticleSystem(ref ObjectGeometry geometry, LTObject* object, const ref EffectView view)
{
	SharedTexture* shared_texture=At!(SharedTexture*)(object, ParticleTextureOffset);
	RenderTexture texture=shared_texture ? view.resolve_texture(shared_texture) : null;
	if (texture && (texture.width==0 || texture.height==0))
		texture=null;

	// two-texel inset; untextured particles use UV 0
	float u_min=0f, v_min=0f, u_max=0f, v_max=0f;
	if (texture)
	{
		u_min=2f/texture.width;
		v_min=2f/texture.height;
		u_max=(texture.width-2f)/texture.width;
		v_max=(texture.height-2f)/texture.height;
	}

	const Mat4 matrix=SetupTransformation(object.pos, object.rot, object.scale);
	const float half_size=2f*At!float(object, ParticleRadiusOffset);
	const int count=At!int(object, ParticleCountOffset);
	ubyte* head=cast(ubyte*)object+ParticleHeadOffset;

	// particle colour x object colour x GlobalLightScale, all 0..255 (no clamp in the original; a port should clamp)
	const float[3] tint=[object.r*view.light_scale[0]/255f, object.g*view.light_scale[1]/255f, object.b*view.light_scale[2]/255f];
	const float alpha=object.a/255f;

	geometry.Begin(Descriptor(texture), DrawGroup.ParticleSystems, ObjectPipe.Blend,
		texture ? (texture.fullbright ? TextureMode.Fullbright : TextureMode.Normal) : TextureMode.Untextured);

	ubyte* particle=At!(ubyte*)(object, ParticleFirstOffset);
	for (int i=0; i<count && particle !is null && particle!=head; ++i, particle=At!(ubyte*)(particle, PSParticleNextOffset))
	{
		const float[3] pos=matrix.TransformPoint(At!(float[3])(particle, PSParticlePosOffset));

		// whole particles only: kept iff near < z < far and inside the side planes, never partially clipped in 3D
		const float z=view.Depth(pos);
		if (!(z>view.near_z && z<view.far_z))
			continue;
		const float[3] relative=[pos[0]-view.camera[0], pos[1]-view.camera[1], pos[2]-view.camera[2]];
		const float x=Dot(relative, view.right), y=Dot(relative, view.up);
		if (!(x>-z*view.tan_half_fov_x && x<z*view.tan_half_fov_x && y>-z*view.tan_half_fov_y && y<z*view.tan_half_fov_y))
			continue;

		const float[3] particle_colour=At!(float[3])(particle, PSParticleColourOffset);
		float[4] colour;
		foreach(channel; 0..3)
		{
			const float c=particle_colour[channel]*tint[channel]/255f;
			colour[channel]=c<0f ? 0f : c>1f ? 1f : c;
		}
		colour[3]=alpha;

		ObjectVertex[4] corners=[
			ObjectVertex(view.Out(Madd(Madd(pos, view.right, -half_size), view.up, half_size)), colour, [u_min, v_min]),
			ObjectVertex(view.Out(Madd(Madd(pos, view.right, half_size), view.up, half_size)), colour, [u_max, v_min]),
			ObjectVertex(view.Out(Madd(Madd(pos, view.right, half_size), view.up, -half_size)), colour, [u_max, v_max]),
			ObjectVertex(view.Out(Madd(Madd(pos, view.right, -half_size), view.up, -half_size)), colour, [u_min, v_max])
		];
		EmitQuad(geometry, corners);
	}

	geometry.End();
}

//// Polygrids (polygrid.md)

enum : size_t
{
	PolyGridDataOffset=0x128, // int8 / uint8 heights, width x height
	PolyGridIndicesOffset=0x12c, // WORD triangle list built by the engine
	PolyGridSpriteOffset=0x130,
	PolyGridCurFrameOffset=0x13c, // sprite tracker's current frame -> { SharedTexture* }
	PolyGridEnvMapOffset=0x148,
	PolyGridPanOffset=0x14c, // x, y
	PolyGridTexScaleOffset=0x154, // x, y
	PolyGridIndexCountOffset=0x160,
	PolyGridWidthOffset=0x170,
	PolyGridHeightOffset=0x174,
	PolyGridColourTableOffset=0x178, // 256 x { r, g, b, a } floats 0..255
}

void DrawPolyGrid(ref ObjectGeometry geometry, LTObject* object, const ref EffectView view)
{
	ubyte* data=At!(ubyte*)(object, PolyGridDataOffset);
	ushort* indices=At!(ushort*)(object, PolyGridIndicesOffset);
	const uint index_count=At!uint(object, PolyGridIndexCountOffset);
	const uint width=At!uint(object, PolyGridWidthOffset), height=At!uint(object, PolyGridHeightOffset);
	if (data is null || indices is null || index_count<3 || width<2 || height<2 || width*height>65536)
		return;

	RenderTexture base_texture;
	if (At!(void*)(object, PolyGridSpriteOffset) !is null)
	{
		SharedTexture** frame=At!(SharedTexture**)(object, PolyGridCurFrameOffset);
		if (frame && *frame)
			base_texture=view.resolve_texture(*frame);
	}
	SharedTexture* env_shared=At!(SharedTexture*)(object, PolyGridEnvMapOffset);
	RenderTexture env_texture=env_shared ? view.resolve_texture(env_shared) : null;

	const bool unsigned_samples=(object.flags & ObjectFlag.PolyGridUnsigned)!=0;

	// object matrix with the grid stretched by (n + 1) / n, then centred
	const float[3] scale=[(width+1f)/width*object.scale[0], object.scale[1], (height+1f)/height*object.scale[2]];
	Mat4 centre=Mat4.Identity();
	centre.m[0][3]=-(width-1f)*0.5f;
	centre.m[1][3]=unsigned_samples ? -128f : 0f;
	centre.m[2][3]=-(height-1f)*0.5f;
	const Mat4 grid=SetupTransformation(object.pos, object.rot, scale)*centre;

	// "fixed B2 UV table": stage 0's 1 / texture size, i.e. the base texture's
	const float u_texel=(base_texture && base_texture.width) ? 1f/base_texture.width : 1f/64;
	const float v_texel=(base_texture && base_texture.height) ? 1f/base_texture.height : 1f/64;
	const float[2] pan=At!(float[2])(object, PolyGridPanOffset);
	const float[2] tex_scale=At!(float[2])(object, PolyGridTexScaleOffset);
	const float u_offset=pan[0]*u_texel, v_offset=pan[1]*v_texel;
	const float u_scale=(tex_scale[0]!=0f ? u_texel/tex_scale[0] : 0f)*object.scale[0]*(width/(width-1f));
	const float v_scale=(tex_scale[1]!=0f ? v_texel/tex_scale[1] : 0f)*object.scale[2]*(height/(height-1f));

	const float[4]* colour_table=cast(const(float[4])*)(cast(ubyte*)object+PolyGridColourTableOffset);
	const float alpha_scale=object.a/255f;

	int Sample(size_t i)
	{
		return unsigned_samples ? cast(int)data[i] : cast(int)(cast(byte)data[i]);
	}

	// vertices once; colour from the sample's table entry through the light scale, no grid or dynamic light
	static ObjectVertex[] scratch; // reused between grids and frames
	if (scratch.length<width*height)
		scratch.length=width*height;
	ObjectVertex[] vertices=scratch[0..width*height];
	foreach(z; 0..height)
		foreach(x; 0..width)
		{
			const size_t i=z*width+x;
			const int sample=Sample(i);
			const float[4] c=colour_table[unsigned_samples ? (sample & 0xFF) : sample+128];
			ObjectVertex* v=&vertices[i];
			v.pos=view.Out(grid.TransformPoint([cast(float)x, cast(float)sample, cast(float)z]));
			v.colour=[cast(int)c[0]*view.light_scale[0]/255f, cast(int)c[1]*view.light_scale[1]/255f,
				cast(int)c[2]*view.light_scale[2]/255f, cast(int)(c[3]*alpha_scale)/255f];
			v.uv=[(x+u_offset)*u_scale, (z+v_offset)*v_scale];
		}

	const bool translucent=object.a!=255;
	const DrawGroup group=view.sky ? DrawGroup.Sky : (translucent ? DrawGroup.TranslucentPolyGrids : DrawGroup.SolidPolyGrids);
	const ObjectPipe pipe=view.sky ? (translucent ? ObjectPipe.BlendNoZ : ObjectPipe.OpaqueNoZ) :
		(translucent ? ObjectPipe.Blend : ObjectPipe.Opaque);

	void Pass(RenderTexture texture)
	{
		geometry.Begin(Descriptor(texture), group, pipe,
			texture ? (texture.fullbright ? TextureMode.Fullbright : TextureMode.Normal) : TextureMode.Untextured);
		foreach(index; indices[0..index_count-index_count%3])
			if (index<vertices.length)
				geometry.Add(vertices[index]);
		geometry.End();
	}

	// pass 1: base texture (or untextured) unless environment-only
	if (!(object.flags & ObjectFlag.PolyGridEnvOnly))
		Pass(base_texture);

	// pass 2: the environment map with slope-based UVs on interior vertices, same blend state as pass 1 (on a solid grid
	// it overwrites pass 1 at equal depth)
	if (env_texture)
	{
		foreach(z; 1..height-1)
			foreach(x; 1..width-1)
			{
				const size_t i=z*width+x;
				const int centre_sample=cast(byte)data[i];
				const float left_sum=cast(byte)data[i-1]+centre_sample;
				const float above_sum=cast(byte)data[i-width]+centre_sample;
				import std.math: sqrt;
				const float length=sqrt(left_sum*left_sum+above_sum*above_sum);
				if (length>0f)
					vertices[i].uv=[0.5f+left_sum/length, 0.5f+above_sum/length];
			}
		Pass(env_texture);
	}
}

//// Line systems (linesystem.md)

enum : size_t
{
	LineSystemSentinelOffset=0x130, // embedded segment-shaped head
	LineSystemFirstOffset=0x170,

	SegmentStartOffset=0x00,
	SegmentStartColourOffset=0x0c, // RGBA floats 0..1
	SegmentEndOffset=0x1c,
	SegmentEndColourOffset=0x28,
	SegmentNextOffset=0x40,
}

void DrawLineSystem(ref ObjectGeometry geometry, LTObject* object, const ref EffectView view)
{
	const Mat4 matrix=SetupTransformation(object.pos, object.rot, object.scale);
	ubyte* sentinel=cast(ubyte*)object+LineSystemSentinelOffset;
	const float object_alpha=object.a/255f;

	// untextured, unlit, never fogged; segment colour with its alpha times the object's
	geometry.Begin(VkDescriptorSetOf.init, DrawGroup.LineSystems, ObjectPipe.Lines, TextureMode.Untextured);

	uint guard=0;
	for (ubyte* segment=At!(ubyte*)(object, LineSystemFirstOffset); segment !is null && segment!=sentinel && guard<1_000_000;
		segment=At!(ubyte*)(segment, SegmentNextOffset), ++guard)
	{
		foreach(end; 0..2)
		{
			const float[3] point=At!(float[3])(segment, end ? SegmentEndOffset : SegmentStartOffset);
			const float[4] c=At!(float[4])(segment, end ? SegmentEndColourOffset : SegmentStartColourOffset);
			ObjectVertex vertex={
				pos: view.Out(matrix.TransformPoint(point)),
				colour: [c[0], c[1], c[2], c[3]*object_alpha],
				uv: [0f, 0f]
			};
			geometry.Add(vertex);
		}
	}

	geometry.End();
}
