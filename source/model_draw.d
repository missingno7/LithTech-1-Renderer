module ModelDraw;

/+
 + Model objects, ported from blood2_recon's d3d.ren model chain (docs/seed_pass/port_notes/model.md):
 + d3d_model_core.cpp (object matrix, body), d3d_model_pose.cpp (node pose), d3d_model_frame_lighting.cpp (light),
 + the vertex dispatch at 0x10e7c (16-step light ramp) and d3d_model_mesh.cpp (faces, per-face UVs).
 + Output is world-space triangles; the GPU does projection, clipping and depth instead of d3d.ren's CPU TL path.
 +
 + Not ported: LOD selection and collapse (always full detail), CoolFog, the tint pass.
 +/

import LTObjects;
import SceneGeometry;
import RendererTypes: SceneDesc, ModelHookData;
import Texture: SharedTexture, RenderTexture;
import WorldBsp: MainWorld, WorldBsp, Node, SurfaceFlags;
import erupted: VkDescriptorSet;

// ModelInstance, port ABI 4.2 (offsets from the object)
enum : size_t
{
	ModelSkinOffset=0x128,
	ModelDataOffset=0x140,      // AnimTracker +0x14
	ModelPrevAnimOffset=0x14c,  // AnimTracker +0x20
	ModelPrevFrameOffset=0x158, // AnimTracker +0x2c
	ModelCurAnimOffset=0x15c,   // AnimTracker +0x30
	ModelCurFrameOffset=0x168,  // AnimTracker +0x3c
	ModelBlendOffset=0x16c,     // AnimTracker +0x40
	ModelHiddenNodesOffset=0x17c,
}

// Model_t, port ABI 4.3 and the d3d_model_* views
enum : size_t
{
	ModelVertexAnimNodeCountOffset=0x8c, // nodes with per-vertex animation (d3d.ren 0x3f200)
	ModelNodeVisibilityCountOffset=0x90,
	ModelVerticesOffset=0x98,
	ModelVertexCountOffset=0x9c,
	ModelFaceCountOffset=0xa0,
	ModelFacesOffset=0xa4,
	ModelFaceUVsOffset=0xa8, // three (u, v) texel pairs per face
	ModelMatrixCountOffset=0xcc,
}

struct ModelVertex // 0x1c
{
	float[3] pos;
	float u, v;
	byte nx, ny, nz; // unit normal * 127
	ubyte node; // node matrix index
	ushort remap_a, remap_b; // LOD collapse
}
static assert(ModelVertex.sizeof==0x1c);

align(1) struct ModelFace // 10 bytes
{
	align(1):
	ushort[3] vertex;
	ubyte[3] unknown;
	ubyte node_visibility; // index into the hidden-node table
}
static assert(ModelFace.sizeof==10);

struct NodeFrame // 0x1c
{
	float[3] pos;
	float[4] rot; // x, y, z, w
}

// AnimNode (0x34) / ModelNode (0x38) / ModelAnim (0x74, root AnimNode at +0x40)
enum : size_t
{
	AnimNodeSize=0x34,
	AnimNodeModelNodeOffset=0x00,
	AnimNodeAffineOffset=0x10, // six floats: scale diagonal, translation (nodes with ModelNode flag 4)
	AnimNodeFramesOffset=0x28,
	AnimNodeChildrenOffset=0x30,
	ModelNodeFlagsOffset=0x2e,
	ModelNodeChildCountOffset=0x34,
	ModelAnimRootOffset=0x40,
	ModelAnimVertexFramesOffset=0x14, // per vertex-animated node frame info
}

alias ModelHookFn=extern(C) void function(ModelHookData*, void*);

// Environment maps ("chrome"; port_notes/model.md, Render state per pass): a model with FLAG_ENVIRONMENTMAP, or every
// model with EnvMapAll, is drawn first with the world's environment map (RenderStruct +0xdc, Blood II levels set
// spritetextures\chrome.dtx on high detail), then its skin is blended over it with SRCALPHA / INVSRCALPHA, so the object
// alpha (Blood II's "chrome value") sets how much skin covers the chrome. EnvMapAll draws the environment map alone.
// The environment UVs project the world-space normal: u = (n . pose row 0) * EnvUScale + EnvUAdd, likewise v with row 1
// (d3d.ren 0x10de0), with EnvUScale = (1/254) / EnvScale and EnvUAdd = EnvPanSpeed * camera x + 0.5 (z for v).
struct ModelEnvSettings
{
	RenderTexture texture; // null: no environment map
	bool enable; // console EnvMapEnable
	bool all; // console EnvMapAll
	float[2] scale; // EnvUScale, EnvVScale
	float[2] add; // EnvUAdd, EnvVAdd
}

// CloudMapLight (d3d.ren 0x10680): a model standing on a cloud-shadowed floor (surface flag 0x8000) has its directional
// light dimmed by the cloud map's grey level under it. Blood II's detail settings turn it off.
struct CloudLightSettings
{
	bool enable;
	const(ubyte)[] intensity; // the cloud texture's top mip as grey levels, (r + g + b) / 3 of its palette
	uint width, height;
	float[2] offset, scale; // GLOBALPAN_SKYSHADOW x / z offset and scale
	WorldBsp* bsp;
}
__gshared CloudLightSettings g_CloudLight;

// d3d.ren draws every model through this; geometry goes into `geometry` in world space
void DrawModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene, MainWorld* world,
	const float[3] light_direction, const DynamicLight[] lights, const ModelShadowSettings* shadows,
	const ModelEnvSettings* env, scope RenderTexture delegate(SharedTexture*) resolve_texture)
{
	void* model=At!(void*)(object, ModelDataOffset);
	void* prev_anim=At!(void*)(object, ModelPrevAnimOffset);
	void* cur_anim=At!(void*)(object, ModelCurAnimOffset);
	if (model is null || prev_anim is null || cur_anim is null)
		return;

	const uint prev_frame=At!uint(object, ModelPrevFrameOffset);
	const uint cur_frame=At!uint(object, ModelCurFrameOffset);
	const float blend=At!float(object, ModelBlendOffset);

	const uint matrix_count=At!uint(model, ModelMatrixCountOffset);
	if (matrix_count==0 || matrix_count>1024)
		return;

	//// pose
	if (_pose.length<matrix_count)
		_pose.length=matrix_count;

	Mat4 object_to_world=BuildObjectMatrix(object);
	PoseContext pose={ frame_a: prev_frame, frame_b: cur_frame, blend: blend, output: _pose[0..matrix_count] };
	pose.BlendNode(prev_anim+ModelAnimRootOffset, cur_anim+ModelAnimRootOffset, object_to_world, 0);

	if (!g_DisableVertexAnimation)
		BlendVertexAnimation(model, prev_anim, cur_anim, prev_frame, cur_frame, blend);

	debug DumpModelOnce(object, model, matrix_count);

	//// light ramp (and the same light unstepped, without the dynamic lights, for the modern lighting)
	uint draw_flags;
	BatchLighting modern;
	float[4][16] ramp=LightRamp(object, scene, world, lights, draw_flags, modern);

	//// hidden nodes (d3d_model_core.cpp ApplyHiddenNodeList)
	_node_visible[]=true;
	if (ubyte* hidden=At!(ubyte*)(object, ModelHiddenNodesOffset))
		for(; *hidden!=0xFF; ++hidden)
			_node_visible[*hidden]=false;

	//// mesh: full detail faces with their per-face UVs (d3d_model_mesh.cpp streamed path at LOD 0)
	ModelVertex* vertices=At!(ModelVertex*)(model, ModelVerticesOffset);
	const uint vertex_count=At!uint(model, ModelVertexCountOffset);
	ModelFace* faces=At!(ModelFace*)(model, ModelFacesOffset);
	const uint face_count=At!uint(model, ModelFaceCountOffset);
	const(float)* face_uvs=At!(float*)(model, ModelFaceUVsOffset);
	if (vertices is null || faces is null || face_uvs is null)
		return;

	// solid iff the object is fully opaque (d3d_ProcessModel)
	const bool translucent=object.a!=0xFF;
	RenderTexture skin=resolve_texture(At!(SharedTexture*)(object, ModelSkinOffset));
	const bool chrome=env && env.texture && env.enable && (env.all || (object.flags & ObjectFlag.EnvironmentMap));

	_mesh.length=0;
	_mesh.assumeSafeAppend();
	_env_uvs.length=0;
	_env_uvs.assumeSafeAppend();

	foreach(face_index; 0..face_count)
	{
		const ModelFace* face=faces+face_index;
		if (!_node_visible[face.node_visibility])
			continue;
		if (face.vertex[0]>=vertex_count || face.vertex[1]>=vertex_count || face.vertex[2]>=vertex_count)
			continue;

		foreach(corner; 0..3)
		{
			const ModelVertex* source=vertices+face.vertex[corner];
			const ref Mat4 node=_pose[source.node<matrix_count ? source.node : 0];

			// d3d.ren dots the int8 normal with the light direction in node space; this is the same dot in world space
			const float[3] normal=Normalised(node.TransformVector([source.nx/127f, source.ny/127f, source.nz/127f]));
			int step=cast(int)((Dot(normal, light_direction)*(127f*1024f)+0x20000)/(1 << 14));
			if (step<0) step=0;
			else if (step>15) step=15;

			ObjectVertex vertex={
				pos: node.TransformPoint(source.pos),
				colour: ramp[step],
				uv: [face_uvs[face_index*6+corner*2], face_uvs[face_index*6+corner*2+1]],
				normal: normal
			};
			_mesh~=vertex;

			if (chrome)
			{
				const float[3] n=[source.nx, source.ny, source.nz]; // unscaled int8, like d3d.ren
				_env_uvs~=[
					(n[0]*node.m[0][0]+n[1]*node.m[0][1]+n[2]*node.m[0][2])*env.scale[0]+env.add[0],
					(n[0]*node.m[1][0]+n[1]*node.m[1][1]+n[2]*node.m[1][2])*env.scale[1]+env.add[1]];
			}
		}
	}

	const DrawGroup group=translucent ? geometry.translucent_group : geometry.solid_group;
	const ObjectPipe pipe=translucent ? geometry.translucent_pipe : geometry.solid_pipe;
	const TextureMode skin_mode=(skin && skin.fullbright) ? TextureMode.Fullbright : TextureMode.Normal;
	const VkDescriptorSet skin_texture=skin ? skin.texture_descriptor : VkDescriptorSet.init;

	geometry.lighting=modern;
	scope(exit) geometry.lighting=BatchLighting.init;

	// the model's bounds and grid light, for the static lamps (static_lighting.d)
	if (_mesh.length)
	{
		float[3] low=_mesh[0].pos, high=_mesh[0].pos;
		foreach(ref vertex; _mesh)
			foreach(axis; 0..3)
			{
				if (vertex.pos[axis]<low[axis]) low[axis]=vertex.pos[axis];
				if (vertex.pos[axis]>high[axis]) high[axis]=vertex.pos[axis];
			}
		import std.math: sqrt;
		const float[3] half=[(high[0]-low[0])*0.5f, (high[1]-low[1])*0.5f, (high[2]-low[2])*0.5f];
		import StaticLighting: ModelRecord;
		ModelRecord record={
			object: object,
			centre: [low[0]+half[0], low[1]+half[1], low[2]+half[2]],
			radius: sqrt(half[0]*half[0]+half[1]*half[1]+half[2]*half[2]),
			directional: modern.directional,
			solid: !translucent && !geometry.object_list
		};
		geometry.model_index=cast(int)geometry.models.length;
		geometry.models~=record;
	}
	scope(exit) geometry.model_index=-1;

	if (chrome)
	{
		geometry.Begin(env.texture.texture_descriptor, group, pipe, TextureMode.Normal);
		foreach(i, vertex; _mesh)
		{
			vertex.uv=_env_uvs[i];
			geometry.Add(vertex);
		}
		geometry.End();
	}

	if (!chrome || !env.all)
	{
		// over the environment map the skin is blended, still writing depth in the solid queue
		geometry.Begin(skin_texture, group, (chrome && !translucent) ? ObjectPipe.BlendDepthWrite : pipe, skin_mode);
		foreach(ref vertex; _mesh)
			geometry.Add(vertex);
		geometry.End();
	}

	// FLAG_SHADOW, after the model hook (d3d.ren calls the shadow pass from the model backend when that bit is set)
	geometry.lighting=BatchLighting.init;
	geometry.model_index=-1;
	if (draw_flags & ObjectFlag.Shadow)
		g_ShadowStats[0]++;
	if (shadows && (draw_flags & ObjectFlag.Shadow))
		DrawModelShadows(geometry, object, vertices, vertex_count, faces, face_count, _pose[0..matrix_count], *shadows,
			translucent);
}

// what the shadow pass needs from the scene
struct ModelShadowSettings
{
	float[3] camera;
	float[3] forward; // camera axis, for the depth bias
	WorldBsp* bsp; // traced for the floor
	int max_shadows; // console MaxModelShadows (Blood II: 1), at most 3
	float z_range; // console ShadowZRange (17)
	float near_z;
}

// d3d.ren model shadows (blood2_recon d3d_model_shadow_*.cpp, written-unproven; 0x28444 caller, 0x126d0 probe, 0x12740
// plane, 0x8990 / 0x6d10 geometry): the posed mesh flattened along a fixed direction onto the floor under the model,
// drawn black with an alpha fading out by 1000 units. Each face gets its own depth bias towards the camera (stepping
// from -ShadowZRange to 0) and depth is written, so overlapping faces darken once and the shadow doesn't z-fight the
// floor. No texture, no fog.
void DrawModelShadows(ref ObjectGeometry geometry, LTObject* object, ModelVertex* vertices, uint vertex_count,
	ModelFace* faces, uint face_count, const Mat4[] pose, const ref ModelShadowSettings settings, bool translucent)
{
	import std.math: sqrt;

	if (settings.bsp is null || settings.bsp.root_node is null || settings.max_shadows<=0)
		return;

	// fade with the camera distance; the floor probe gives up beyond 1500 units
	const float[3] to_model=[object.pos[0]-settings.camera[0], object.pos[1]-settings.camera[1], object.pos[2]-settings.camera[2]];
	const float distance=sqrt(Dot(to_model, to_model));
	if (distance>1500f)
		return;
	float fade=(1000f-(distance<1000f ? distance : 1000f))*0.001f*255f;
	if (fade>110f)
		fade=110f;
	const float alpha=cast(int)fade/255f;
	if (alpha<=0f)
		return;

	// the floor: a vertical 3000-unit probe down through the world; only floor-like planes take a shadow
	float[4] plane;
	const float[3] probe_end=[object.pos[0], object.pos[1]-3000f, object.pos[2]];
	if (!TraceSegment(cast(Node*)settings.bsp.root_node, object.pos, probe_end, plane))
		return;
	g_ShadowStats[1]++;
	if (plane[1]<=0.7f)
		return;
	g_ShadowStats[2]++;
	const float[3] normal=plane[0..3];

	// the fixed shadow directions (d3d.ren model PreFrame 0x12840), one per shadow
	static immutable float[3][3] raw_directions=[[0f, -1f, -1f], [-2f, -2f, -2f], [2f, -2f, -1f]];
	const int shadow_count=settings.max_shadows>3 ? 3 : settings.max_shadows;

	uint visible_faces=0;
	foreach(face_index; 0..face_count)
		if (_node_visible[faces[face_index].node_visibility])
			visible_faces++;
	if (visible_faces==0)
		return;
	const float bias_step=settings.z_range/visible_faces;

	foreach(shadow; 0..shadow_count)
	{
		const float[3] direction=Normalised(raw_directions[shadow]);
		const float along=Dot(normal, direction);
		if (along> -0.0001f && along<0.0001f)
			continue;

		geometry.Begin(VkDescriptorSet.init, translucent ? geometry.translucent_group : geometry.solid_group,
			ObjectPipe.BlendDepthWrite, TextureMode.Untextured, true);

		float bias=-settings.z_range;
		foreach(face_index; 0..face_count)
		{
			const ModelFace* face=faces+face_index;
			if (!_node_visible[face.node_visibility])
				continue;
			if (face.vertex[0]>=vertex_count || face.vertex[1]>=vertex_count || face.vertex[2]>=vertex_count)
				continue;

			ObjectVertex[3] corners;
			bool usable=true;
			foreach(corner; 0..3)
			{
				const ModelVertex* source=vertices+face.vertex[corner];
				const float[3] posed=pose[source.node<pose.length ? source.node : 0].TransformPoint(source.pos);

				// slide along the shadow direction onto the floor plane
				const float t=(Dot(normal, posed)-plane[3])/along;
				float[3] p=[posed[0]-direction[0]*t, posed[1]-direction[1]*t, posed[2]-direction[2]*t];

				// the depth bias, as a slide along the view ray (same screen position, nearer depth)
				const float[3] relative=[p[0]-settings.camera[0], p[1]-settings.camera[1], p[2]-settings.camera[2]];
				const float z=Dot(relative, settings.forward);
				if (z<=settings.near_z)
				{
					usable=false;
					break;
				}
				float biased=z+bias;
				if (biased<settings.near_z)
					biased=settings.near_z;
				foreach(axis; 0..3)
					p[axis]=settings.camera[axis]+relative[axis]*(biased/z);

				corners[corner].pos=p;
				corners[corner].colour=[0f, 0f, 0f, alpha];
				corners[corner].uv=[0f, 0f];
			}
			bias+=bias_step;
			if (!usable)
				continue;

			foreach(ref corner; corners)
				geometry.Add(corner);
		}

		geometry.End();
	}
}

// model shadows for the log: models with FLAG_SHADOW, floor traces that hit, hits on a floor-like plane
__gshared uint[3] g_ShadowStats;

// diagnostics, set every scene from the console variables d_ModelVertexAnim and d_ModelFlip (both default 1)
__gshared bool g_DisableVertexAnimation;
__gshared bool g_DisableModelFlip;

private:

Mat4[] _pose;
bool[256] _node_visible;
ObjectVertex[] _mesh; // the model's triangles, drawn once per pass
float[2][] _env_uvs; // and their environment-map UVs

debug void DumpModelOnce(LTObject* object, void* model, uint matrix_count)
{
	import VulkanRender: test_out;

	static bool[void*] dumped;
	if (model in dumped || dumped.length>=8)
		return;
	dumped[model]=true;

	test_out.writefln("== model %s obj %s pos %s rot %s scale %s colour %s,%s,%s,%s flags %x", model, object, object.pos,
		object.rot, object.scale, object.r, object.g, object.b, object.a, object.flags);
	foreach(offset; [0x84, 0x88, 0x8c, 0x90, 0x94, 0x9c, 0xa0, 0xb0, 0xcc])
		test_out.writef(" +%x=%d", offset, At!uint(model, offset));
	test_out.writeln();
	test_out.writeln(" no vertex anim: ", g_DisableVertexAnimation, " prev frame ", At!uint(object, ModelPrevFrameOffset),
		" cur frame ", At!uint(object, ModelCurFrameOffset), " blend ", At!float(object, ModelBlendOffset));

	ModelVertex* vertices=At!(ModelVertex*)(model, ModelVerticesOffset);
	foreach(i; 0..4)
		test_out.writeln(" v", i, ": ", vertices[i].pos, " uv ", vertices[i].u, ",", vertices[i].v, " n ", vertices[i].nx, ",",
			vertices[i].ny, ",", vertices[i].nz, " node ", vertices[i].node);

	const(float)* uvs=At!(float*)(model, ModelFaceUVsOffset);
	test_out.writeln(" face uv0: ", uvs[0..6]);

	foreach(i; 0..(matrix_count<3 ? matrix_count : 3))
		test_out.writeln(" m", i, ": ", _pose[i].m);

	// node positions in the object's own frame: x right, y up, z forward (inverse object rotation, no scale/flip)
	{
		import std.string: fromStringz;

		const Mat4 rotation=QuatToMatrix(object.rot);
		void** nodes=At!(void**)(model, 0x80);
		const uint node_count=At!uint(model, 0x84);
		foreach(i; 0..(node_count<64 ? node_count : 64))
		{
			void* node=nodes[i];
			const ushort index=At!ushort(node, 0x2c);
			if (index>=matrix_count)
				continue;
			const float[3] world=[_pose[index].m[0][3]-object.pos[0], _pose[index].m[1][3]-object.pos[1], _pose[index].m[2][3]-object.pos[2]];
			float[3] local;
			foreach(axis; 0..3) // transpose of the rotation
				local[axis]=rotation.m[0][axis]*world[0]+rotation.m[1][axis]*world[1]+rotation.m[2][axis]*world[2];
			test_out.writefln("  node %2d idx %2d flags %x %-16s local %6.1f %6.1f %6.1f", i, index, At!ushort(node, 0x2e),
				At!(char*)(node, 0).fromStringz, local[0], local[1], local[2]);
		}
	}
	test_out.flush();
}

// d3d_model_core.cpp ours_BuildObjectMatrix
Mat4 BuildObjectMatrix(LTObject* object)
{
	// the original sanitises the object's own quaternion in place
	foreach(i, ref component; object.rot)
		if (!(component>=-100_000f && component<=100_000f))
			component=(i==3) ? 1f : 0f;

	Mat4 matrix=QuatToMatrix(object.rot);
	foreach(row; 0..3)
		foreach(column; 0..3)
			matrix.m[row][column]*=object.scale[column];

	// handedness change after scaling: negate the third column
	if (!g_DisableModelFlip)
		foreach(row; 0..4)
			matrix.m[row][2]=-matrix.m[row][2];

	matrix.m[0][3]=object.pos[0];
	matrix.m[1][3]=object.pos[1];
	matrix.m[2][3]=object.pos[2];
	matrix.m[3][0]=0f;
	matrix.m[3][1]=0f;
	matrix.m[3][3]=1f;
	return matrix;
}

// d3d_model_pose.cpp; output is one matrix per node in pre-order
struct PoseContext
{
	uint frame_a, frame_b;
	float blend;
	Mat4[] output;

	size_t BlendNode(void* node_a, void* node_b, const ref Mat4 parent, size_t index)
	{
		if (index>=output.length)
			return index;

		NodeFrame* frames_a=At!(NodeFrame*)(node_a, AnimNodeFramesOffset);
		NodeFrame* frames_b=At!(NodeFrame*)(node_b, AnimNodeFramesOffset);
		void* model_node=At!(void*)(node_a, AnimNodeModelNodeOffset);
		if (frames_a is null || frames_b is null || model_node is null)
		{
			output[index]=parent;
			return index+1;
		}

		const NodeFrame* a=frames_a+frame_a;
		const NodeFrame* b=frames_b+frame_b;
		Mat4 local=QuatToMatrix(KeyRotation(Slerp(a.rot, b.rot, blend)));
		foreach(i; 0..3)
			local.m[i][3]=a.pos[i]+(b.pos[i]-a.pos[i])*blend;
		output[index]=parent*local;

		size_t next=index+1;
		const uint child_count=At!uint(model_node, ModelNodeChildCountOffset);
		ubyte* children_a=At!(ubyte*)(node_a, AnimNodeChildrenOffset);
		ubyte* children_b=At!(ubyte*)(node_b, AnimNodeChildrenOffset);
		foreach(i; 0..child_count)
			next=BlendNode(children_a+i*AnimNodeSize, children_b+i*AnimNodeSize, output[index], next);

		// applied after the children were posed from the unmodified matrix
		if (At!ubyte(model_node, ModelNodeFlagsOffset) & 4)
		{
			const float* affine_a=&At!float(node_a, AnimNodeAffineOffset);
			const float* affine_b=&At!float(node_b, AnimNodeAffineOffset);
			float[6] v;
			foreach(i; 0..6)
				v[i]=affine_a[i]+(affine_b[i]-affine_a[i])*blend;

			Mat4 affine=Mat4.Identity();
			affine.m[0][0]=v[0]; affine.m[0][3]=v[3];
			affine.m[1][1]=v[1]; affine.m[1][3]=v[4];
			affine.m[2][2]=v[2]; affine.m[2][3]=v[5];
			output[index]=output[index]*affine;
		}

		return next;
	}
}

// Node rotations use d3d.ren's quaternion-to-matrix at 0x3e1d0, which is the transpose of the standard one (strict in
// blood2_recon since 2026-10-08, port_notes/model.md). The transpose of a rotation is the rotation by the conjugate.
// Found here first by comparing the opening cutscene with d3d.ren: the untransposed form splays limbs and loses heads.
float[4] KeyRotation(const float[4] q)
{
	return [-q[0], -q[1], -q[2], q[3]];
}

float[4] Slerp(const float[4] a, const float[4] b_in, float t)
{
	import std.math: atan2, sin, sqrt;

	float dot=a[0]*b_in[0]+a[1]*b_in[1]+a[2]*b_in[2]+a[3]*b_in[3];
	float[4] b=b_in;
	if (dot<0f)
	{
		dot=-dot;
		b[]=-b[];
	}

	float scale_a=1f-t, scale_b=t;
	if ((1.0-dot)>0.00001f)
	{
		const float omega=atan2(sqrt((1f+dot)*(1f-dot)), dot);
		const float sin_omega=sin(omega);
		scale_a=sin((1f-t)*omega)/sin_omega;
		scale_b=sin(t*omega)/sin_omega;
	}

	float[4] result;
	foreach(i; 0..4)
		result[i]=scale_a*a[i]+scale_b*b[i];
	return result;
}

// d3d.ren 0x3f200: nodes with per-vertex animation rewrite the model's vertex positions each frame (byte-packed, the
// node's affine matrix scales them back)
void BlendVertexAnimation(void* model, void* anim_a, void* anim_b, uint frame_a, uint frame_b, float blend)
{
	const uint node_count=At!uint(model, ModelVertexAnimNodeCountOffset);
	ModelVertex* vertices=At!(ModelVertex*)(model, ModelVerticesOffset);
	const uint vertex_count=At!uint(model, ModelVertexCountOffset);
	void** infos_a=At!(void**)(anim_a, ModelAnimVertexFramesOffset);
	void** infos_b=At!(void**)(anim_b, ModelAnimVertexFramesOffset);
	if (node_count==0 || vertices is null || infos_a is null || infos_b is null)
		return;

	const int q14=cast(int)(blend*16384f);
	foreach(node; 0..node_count)
	{
		ubyte* info_a=cast(ubyte*)infos_a[node];
		ubyte* info_b=cast(ubyte*)infos_b[node];
		if (info_a is null || info_b is null)
			continue;

		ubyte* data_a=At!(ubyte*)(info_a, 0);
		ubyte* data_b=At!(ubyte*)(info_b, 0);
		if (data_a is null || data_b is null)
			continue;

		const uint count_a=At!uint(data_a, 0x24);
		const uint count_b=At!uint(data_b, 0x24);
		const(ubyte)* packed_a=At!(ubyte*)(info_a, 8);
		const(ubyte)* packed_b=At!(ubyte*)(info_b, 8);
		const(ushort)* vertex_map=At!(ushort*)(data_a, 0x20);
		if (packed_a is null || packed_b is null || vertex_map is null)
			continue;

		packed_a+=frame_a*count_a*3;
		packed_b+=frame_b*count_b*3;
		foreach(point; 0..count_a)
		{
			if (vertex_map[point]<vertex_count)
			{
				ModelVertex* destination=vertices+vertex_map[point];
				foreach(axis; 0..3)
				{
					const int value_a=packed_a[axis], value_b=packed_b[axis];
					destination.pos[axis]=((value_a << 14)+(value_b-value_a)*q14)*(1f/16384f);
				}
			}
			packed_a+=3;
			packed_b+=3;
		}
	}
}

// d3d.ren 0x10680: the factor CloudMapLight puts on the directional light, 1 when it doesn't apply. The floor is
// looked for 200 units below; the factor grows with the height above it.
float CloudLight(const float[3] pos)
{
	with (g_CloudLight)
	{
		if (!enable || intensity.length==0 || bsp is null || bsp.root_node is null || scale[0]==0f || scale[1]==0f)
			return 1f;

		float[4] plane;
		Node* node;
		float[3] hit;
		if (!TraceSegment(cast(Node*)bsp.root_node, pos, [pos[0], pos[1]-200f, pos[2]], plane, node, hit))
			return 1f;
		if (node is null || node.polygons is null || node.polygons.surface is null ||
			!(node.polygons.surface.flags & SurfaceFlags.PanningSky))
			return 1f;

		const int x=cast(int)((offset[0]+pos[0])/scale[0]) & (width-1);
		const int y=cast(int)((offset[1]+pos[2])/scale[1]) & (height-1);
		float light=(pos[1]-hit[1])*0.0025f+intensity[x+y*width]*(1f/255f);
		return light<0.2f ? 0.2f : light>1f ? 1f : light;
	}
}

// d3d_model_frame_lighting.cpp ours_SetupModelFrameState + the 16-entry ramp of the vertex dispatch (0x10e7c).
// `modern` gets the ramp's ambient and directional light for the modern lighting, which lights the model per pixel and
// adds the dynamic lights there instead of in the ambient light.
float[4][16] LightRamp(LTObject* object, SceneDesc* scene, MainWorld* world, const DynamicLight[] lights,
	out uint draw_flags, out BatchLighting modern)
{
	import gl3n.linalg: vec3;

	// the object flags this draw uses: the model hook may change them for this frame only (FLAG_SHADOW etc.)
	draw_flags=object.flags;

	static float Clamp255(float value) { return value<0f ? 0f : value>255f ? 255f : value; }

	const float[3] scale=scene.global_light_scale.vector;
	float[3] ambient=[object.r, object.g, object.b];
	ambient[]+=scene.model_light_add[];
	float[3] static_ambient=ambient;
	// the dynamic lights at the object (d3d_CalcLightAdd), unless FLAG_NOLIGHT
	if (!(object.flags & ObjectFlag.NoLight))
		ambient[]+=CalcLightAdd(object.pos, lights)[];
	ambient[]*=scale[];
	static_ambient[]*=scale[];
	foreach(i; 0..3)
	{
		ambient[i]=Clamp255(ambient[i]);
		static_ambient[i]=Clamp255(static_ambient[i]);
	}
	// what the dynamic lights added (after the clamp), taken off the hook's result again for the modern lighting
	float[3] dynamic_add;
	dynamic_add[]=ambient[]-static_ambient[];

	// the client shell may change the ambient light through the model hook
	if (ModelHookFn hook=cast(ModelHookFn)scene.model_hook_fnc_ptr)
	{
		vec3 light_add=vec3(ambient);
		ModelHookData data;
		data.object=cast(typeof(data.object))object;
		data.flags=cast(typeof(data.flags))1;
		data.object_flags=cast(typeof(data.object_flags))object.flags;
		data.light_add=&light_add;
		hook(&data, scene.model_hook_user);
		ambient=light_add.vector;
		draw_flags=cast(uint)data.object_flags;
	}

	float[3] modern_ambient;
	foreach(i; 0..3)
		modern_ambient[i]=Clamp255(ambient[i]-dynamic_add[i]);

	const bool lit=!(object.flags & ObjectFlag.NoLight);
	const float[3] grid=(lit && world) ? SampleLightGrid(world, object.pos) : [0f, 0f, 0f];
	const float cloud=lit ? CloudLight(object.pos) : 1f;

	// the light grid's directional light, capped so that ambient + directional stays within 255
	float[3] Directional(const float[3] base_ambient)
	{
		float[3] directional;
		foreach(i; 0..3)
			directional[i]=(255f-base_ambient[i])*scale[i];

		if (lit)
		{
			foreach(i; 0..3)
			{
				const float cap=directional[i];
				directional[i]=(grid[i]+scene.model_dir_add[i])*scale[i];
				if (directional[i]>cap)
					directional[i]=cap;
			}
			directional[]*=cloud;
		}
		return directional;
	}
	const float[3] directional=Directional(ambient);

	modern.kind=LightingKind.Model;
	const float[3] modern_directional=Directional(modern_ambient);
	foreach(i; 0..3)
	{
		modern.ambient[i]=modern_ambient[i]/255f;
		modern.directional[i]=modern_directional[i]/255f;
	}

	float[4][16] ramp;
	foreach(k; 0..16)
		foreach(i; 0..3)
		{
			float value=ambient[i]+directional[i]*k/16f;
			ramp[k][i]=(value<0f ? 0f : value>255f ? 255f : value)/255f;
		}
	foreach(ref entry; ramp)
		entry[3]=object.a/255f;
	return ramp;
}
