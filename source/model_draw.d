module ModelDraw;

/+
 + Model objects, ported from blood2_recon's d3d.ren model chain (docs/seed_pass/port_notes/model.md):
 + d3d_model_core.cpp (object matrix, body), d3d_model_pose.cpp (node pose), d3d_model_frame_lighting.cpp (light),
 + the vertex dispatch at 0x10e7c (16-step light ramp) and d3d_model_mesh.cpp (faces, per-face UVs).
 + Output is world-space triangles; the GPU does projection, clipping and depth instead of d3d.ren's CPU TL path.
 +
 + Not ported yet: LOD selection and collapse (always full detail), CoolFog, tint pass and
 + environment-map passes, shadows, the "really close" weapon pass.
 +/

import LTObjects;
import SceneGeometry;
import RendererTypes: SceneDesc, ModelHookData;
import Texture: SharedTexture, RenderTexture;
import WorldBsp: MainWorld;
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

// d3d.ren draws every model through this; geometry goes into `geometry` in world space
void DrawModel(ref ObjectGeometry geometry, LTObject* object, SceneDesc* scene, MainWorld* world,
	const float[3] light_direction, const DynamicLight[] lights, scope RenderTexture delegate(SharedTexture*) resolve_texture)
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

	//// light ramp
	float[4][16] ramp=LightRamp(object, scene, world, lights);

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
	geometry.Begin(skin ? skin.texture_descriptor : VkDescriptorSet.init, translucent, skin && skin.fullbright);

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
				uv: [face_uvs[face_index*6+corner*2], face_uvs[face_index*6+corner*2+1]]
			};
			geometry.Add(vertex);
		}
	}

	geometry.End();
}

// diagnostics, set every scene from the console variables d_ModelVertexAnim and d_ModelFlip (both default 1)
__gshared bool g_DisableVertexAnimation;
__gshared bool g_DisableModelFlip;

private:

Mat4[] _pose;
bool[256] _node_visible;

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

// d3d_model_frame_lighting.cpp ours_SetupModelFrameState + the 16-entry ramp of the vertex dispatch (0x10e7c)
float[4][16] LightRamp(LTObject* object, SceneDesc* scene, MainWorld* world, const DynamicLight[] lights)
{
	import gl3n.linalg: vec3;

	const float[3] scale=scene.global_light_scale.vector;
	float[3] ambient=[object.r, object.g, object.b];
	ambient[]+=scene.model_light_add[];
	// the dynamic lights at the object (d3d_CalcLightAdd), unless FLAG_NOLIGHT
	if (!(object.flags & ObjectFlag.NoLight))
		ambient[]+=CalcLightAdd(object.pos, lights)[];
	ambient[]*=scale[];
	foreach(ref channel; ambient)
		channel=channel<0f ? 0f : channel>255f ? 255f : channel;

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
	}

	float[3] directional;
	foreach(i; 0..3)
		directional[i]=(255f-ambient[i])*scale[i];

	if (!(object.flags & ObjectFlag.NoLight))
	{
		const float[3] grid=world ? SampleLightGrid(world, object.pos) : [0f, 0f, 0f];
		foreach(i; 0..3)
		{
			const float cap=directional[i];
			directional[i]=(grid[i]+scene.model_dir_add[i])*scale[i];
			if (directional[i]>cap)
				directional[i]=cap;
		}
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
