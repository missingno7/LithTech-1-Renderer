module LTObjects;

/+
 + Engine-side views the object renderers read, and the small math they share.
 + Offsets follow blood2_recon docs/seed_pass/renderer_port_abi.md (section numbers cited per struct); everything here is a
 + view over engine-owned memory, never allocated by us.
 +/

import RendererTypes: DLink;
import WorldBsp: MainWorld, WorldBsp;

// reads a field of an engine structure at a known offset
pragma(inline, true)
ref T At(T)(const(void)* base, size_t offset)
{
	return *cast(T*)(cast(ubyte*)base+offset);
}

enum ObjectFlag : uint
{
	Visible=0x1,
	PolyGridUnsigned=0x2, // polygrids: samples are uint8 (else int8)
	Shadow=0x2, // models: FLAG_SHADOW, drawn with a shadow on the floor
	ModelTint=0x4,
	RotateableSprite=0x8,
	GlowSprite=0x20, // sprites; on polygrids 0x20 means "environment map only"
	PolyGridEnvOnly=0x20,
	EnvironmentMap=0x20, // models: FLAG_ENVIRONMENTMAP, chrome
	ReallyClose=0x40,
	SpriteBias=0x40,
	SpriteNoZ=0x80,
	NoLight=0x200,
	SkyObject=0x1000, // drawn only by the sky pass, from SceneDesc's sky list
}

// DObject header, ABI 4.1 (0x128 bytes; subclass data follows)
struct LTObject
{
	DLink wt_link;              // +0x00 world tree link (FastNode object lists)
	ubyte[0x28-0x0C] pad0C;
	uint flags;                 // +0x28
	uint user_flags;            // +0x2c
	ubyte r, g, b, a;           // +0x30
	void* attachments;          // +0x34
	float[3] pos;               // +0x38
	float[4] rot;               // +0x44 quaternion x, y, z, w
	float[3] scale;             // +0x54
	float radius;               // +0x60
	ubyte[4] pad64;
	ushort object_id;           // +0x68
	ushort pad6A;
	ushort wt_frame_code;       // +0x6c
	byte type;                  // +0x6e ObjectType
	ubyte priority;             // +0x6f
	ubyte[0x124-0x70] pad70;
	uint list_stop;             // +0x124 a non-zero value ends an object list walk (d3d.ren r_CollectVisibleObjects)

	static assert(flags.offsetof==0x28);
	static assert(r.offsetof==0x30);
	static assert(attachments.offsetof==0x34);
	static assert(pos.offsetof==0x38);
	static assert(rot.offsetof==0x44);
	static assert(scale.offsetof==0x54);
	static assert(type.offsetof==0x6e);
	static assert(list_stop.offsetof==0x124);
	static assert(this.sizeof==0x128);
}

enum size_t AttachmentNextOffset=0x24;

//// FastNode object lists, ABI 2.3 / 2.7: every object is linked into exactly one FastNode through its wt_link

enum size_t WorldBspFastNodesOffset=0x18, WorldBspFastNodeCountOffset=0x1c, FastNodeSize=0x18;

// calls fn for every object in the world tree, attachments included, each object once
void ForEachWorldObject(WorldBsp* bsp, scope void delegate(LTObject*) fn)
{
	ubyte* fast_nodes=At!(ubyte*)(bsp, WorldBspFastNodesOffset);
	const uint fast_node_count=At!uint(bsp, WorldBspFastNodeCountOffset);
	if (fast_nodes is null)
		return;

	foreach(i; 0..fast_node_count)
	{
		DLink* head=cast(DLink*)(fast_nodes+i*FastNodeSize);
		for(DLink* link=head.prev; link!=head && link !is null; link=link.prev)
		{
			LTObject* object=cast(LTObject*)link.data;
			if (object is null)
				continue;
			if (object.list_stop)
				break;
			fn(object);
		}
	}
}

//// Leaf object lists, ABI 2.3 / 2.4: Leaf +0x14 is a DLink sentinel whose links carry an object-tree record with the
//// object at +0x18 (recon world_visibility.cpp r_VLTagPolies). Polygrids are found only this way.

enum size_t WorldBspLeavesOffset=0x30, WorldBspLeafCountOffset=0x34, LeafSize=0x30, LeafObjectsOffset=0x14,
	LeafRecordObjectOffset=0x18;

void ForEachLeafObject(WorldBsp* bsp, scope void delegate(LTObject*) fn)
{
	ubyte* leaves=At!(ubyte*)(bsp, WorldBspLeavesOffset);
	const uint leaf_count=At!uint(bsp, WorldBspLeafCountOffset);
	if (leaves is null)
		return;

	foreach(i; 0..leaf_count)
	{
		DLink* sentinel=cast(DLink*)(leaves+i*LeafSize+LeafObjectsOffset);
		uint guard=0;
		for (DLink* link=sentinel.next; link !is null && link!=sentinel && guard<100_000; link=link.next, ++guard)
		{
			if (link.data is null)
				continue;
			LTObject* object=At!(LTObject*)(link.data, LeafRecordObjectOffset);
			if (object !is null)
				fn(object);
		}
	}
}

//// Segment query through the world BSP, ported from d3d.ren 0xC390 (blood2_recon d3d_bsp_segment_query.cpp), the
//// probe behind model shadows. LithTech's world BSP is a solid-leaf BSP: NODE_OUT (flags & 1) is empty space and
//// NODE_IN (flags & 2) is solid. The segment hits where it first enters solid; the hit plane is the last splitter it
//// crossed, turned to face the start. Sides are classified with a +/-0.1 band, a segment inside the band going to
//// side 1 first.

import WorldBsp: Node;

// plane of the hit: normal x, y, z and distance (n . p = distance), facing a
bool TraceSegment(Node* root, const float[3] a, const float[3] b, out float[4] hit_plane)
{
	Node* hit_node;
	float[3] hit_point;
	return TraceSegment(root, a, b, hit_plane, hit_node, hit_point);
}

// also the node whose splitter was hit (its polygon is the surface hit) and the point where the segment enters solid
bool TraceSegment(Node* root, const float[3] a, const float[3] b, out float[4] hit_plane, out Node* hit_node,
	out float[3] hit_point)
{
	struct Deferred
	{
		Node* far_side;
		Node* split_node;
		float[3] split_point;
		float[3] old_end;
	}
	Deferred[400] deferred; // the native fixed stack
	uint deferred_count=0;

	Node* node=root;
	Node* last_crossing=null;
	float[3] start=a, end=b;

	for (uint guard=0; node !is null && guard<100_000; ++guard)
	{
		if (node.flags & 1) // NODE_OUT: resume the saved far-side interval
		{
			if (deferred_count==0)
				return false;
			Deferred* frame=&deferred[--deferred_count];
			last_crossing=frame.split_node;
			node=frame.far_side;
			start=frame.split_point;
			end=frame.old_end;
			continue;
		}

		if (node.flags & 2) // NODE_IN: a hit, if a splitter was crossed on the way in
		{
			if (last_crossing is null || last_crossing.planes is null)
				return false;
			const float[3] normal=last_crossing.planes.vector.vector;
			const float distance=last_crossing.planes.distance;
			if (Dot(normal, a)-distance>0f)
				hit_plane=[normal[0], normal[1], normal[2], distance];
			else
				hit_plane=[-normal[0], -normal[1], -normal[2], -distance];
			hit_node=last_crossing;
			hit_point=start;
			return true;
		}

		if (node.planes is null)
			return false;
		const float[3] normal=node.planes.vector.vector;
		const float distance=node.planes.distance;
		const float start_distance=Dot(normal, start)-distance;
		const float end_distance=Dot(normal, end)-distance;

		if (start_distance> -0.1f && end_distance> -0.1f)
		{
			node=node.next[1];
			continue;
		}
		if (!(start_distance>=0.1f) && !(end_distance>=0.1f))
		{
			node=node.next[0];
			continue;
		}

		const float fraction=start_distance/(start_distance-end_distance);
		const float[3] crossing=[start[0]+fraction*(end[0]-start[0]), start[1]+fraction*(end[1]-start[1]),
			start[2]+fraction*(end[2]-start[2])];
		const uint near_side=start_distance>0f ? 1 : 0;

		if (deferred_count>=deferred.length)
			return false;
		deferred[deferred_count++]=Deferred(node.next[near_side^1], node, crossing, end);

		node=node.next[near_side];
		end=crossing;
	}
	return false;
}

//// Matrices: row-major, column vectors (translation in m[i][3]), like the LT1 DMatrix

struct Mat4
{
	float[4][4] m;

	static Mat4 Identity()
	{
		Mat4 r;
		foreach(i; 0..4)
			foreach(j; 0..4)
				r.m[i][j]=(i==j) ? 1f : 0f;
		return r;
	}

	Mat4 opBinary(string op : "*")(const ref Mat4 o) const
	{
		Mat4 r;
		foreach(i; 0..4)
			foreach(j; 0..4)
				r.m[i][j]=m[i][0]*o.m[0][j]+m[i][1]*o.m[1][j]+m[i][2]*o.m[2][j]+m[i][3]*o.m[3][j];
		return r;
	}

	float[3] TransformPoint(const float[3] v) const
	{
		return [
			m[0][0]*v[0]+m[0][1]*v[1]+m[0][2]*v[2]+m[0][3],
			m[1][0]*v[0]+m[1][1]*v[1]+m[1][2]*v[2]+m[1][3],
			m[2][0]*v[0]+m[2][1]*v[1]+m[2][2]*v[2]+m[2][3]
		];
	}

	float[3] TransformVector(const float[3] v) const
	{
		return [
			m[0][0]*v[0]+m[0][1]*v[1]+m[0][2]*v[2],
			m[1][0]*v[0]+m[1][1]*v[1]+m[1][2]*v[2],
			m[2][0]*v[0]+m[2][1]*v[1]+m[2][2]*v[2]
		];
	}
}

// quat_ConvertToMatrix, used for object, camera and d3d_SetupTransformation rotations; q is x, y, z, w. Model node
// rotations use d3d.ren's 0x3e1d0 instead, which is this transposed (ModelDraw.KeyRotation conjugates the quaternion).
Mat4 QuatToMatrix(const float[4] q)
{
	const float s=2f/(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);
	const float xs=q[0]*s, ys=q[1]*s, zs=q[2]*s;
	const float wx=q[3]*xs, wy=q[3]*ys, wz=q[3]*zs;
	const float xx=q[0]*xs, xy=q[0]*ys, xz=q[0]*zs;
	const float yy=q[1]*ys, yz=q[1]*zs, zz=q[2]*zs;

	Mat4 r=Mat4.Identity();
	r.m[0][0]=1f-(yy+zz); r.m[0][1]=xy-wz;      r.m[0][2]=xz+wy;
	r.m[1][0]=xy+wz;      r.m[1][1]=1f-(xx+zz); r.m[1][2]=yz-wx;
	r.m[2][0]=xz-wy;      r.m[2][1]=yz+wx;      r.m[2][2]=1f-(xx+yy);
	return r;
}

// d3d_SetupTransformation (recon common/transform.cpp): rotation with its columns scaled, then the translation.
// Unlike the model path there is no handedness flip. The original also resets out-of-range quaternion components in
// place; this works on a copy.
Mat4 SetupTransformation(const float[3] pos, const float[4] rotation, const float[3] scale)
{
	enum float RotationMax=2f; // a unit quaternion's components are within ±1; anything else is garbage

	float[4] q=rotation;
	foreach(i; 0..3)
		if (!(q[i]>=-RotationMax && q[i]<=RotationMax))
			q[i]=0f;
	if (!(q[3]>=-RotationMax && q[3]<=RotationMax))
		q[3]=1f;

	Mat4 r=QuatToMatrix(q);
	foreach(row; 0..3)
	{
		r.m[row][0]*=scale[0];
		r.m[row][1]*=scale[1];
		r.m[row][2]*=scale[2];
		r.m[row][3]=pos[row];
	}
	return r;
}

//// Dynamic lights, ABI 4.9: colour from the header, radius at +0x128

enum size_t LightRadiusOffset=0x128;

struct DynamicLight
{
	float[3] pos;
	float[3] colour; // 0..255
	float radius;
}

// d3d_CalcLightAdd (recon common/3d_ops.cpp): (2c - 255) * 0.7 * (1 - d/r) per light, summed; 0..255 scale
float[3] CalcLightAdd(const float[3] pos, const DynamicLight[] lights)
{
	import std.math: sqrt;

	float[3] add=[0f, 0f, 0f];
	foreach(ref light; lights)
	{
		const float dx=light.pos[0]-pos[0], dy=light.pos[1]-pos[1], dz=light.pos[2]-pos[2];
		const float distance_squared=dx*dx+dy*dy+dz*dz;
		if (distance_squared>=light.radius*light.radius)
			continue;

		const float percent=(1f-sqrt(distance_squared)/light.radius)*0.7f;
		foreach(channel; 0..3)
			add[channel]+=(light.colour[channel]-(255f-light.colour[channel]))*percent;
	}
	return add;
}

float[3] Normalised(float[3] v, float[3] fallback=[1f, 0f, 0f])
{
	import std.math: sqrt;

	const float length=sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
	if (length<0.0001f || length>10_000f)
		return fallback;
	return [v[0]/length, v[1]/length, v[2]/length];
}

float Dot(const float[3] a, const float[3] b)
{
	return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
}

//// Static light grid, ABI 2.2 (MainWorld +0x2c), sampled like d3d.ren w_GetLightVal (0xfde0)

struct LightGridSample { ubyte b, g, r, a; }

struct LightTable
{
	LightGridSample* data;
	uint data_count;
	int[3] dims;
	int[3] dims_minus_1;
	int x_size_times_y_size;
	float[3] block_size;
	float[3] inv_block_size;
	float[3] lookup_start;

	static assert(this.sizeof==0x48);
}

enum size_t MainWorldLightTableOffset=0x2c;

// returns r, g, b in 0..255
float[3] SampleLightGrid(MainWorld* world, const float[3] pos)
{
	import std.math: floor;

	LightTable* table=&At!LightTable(world, MainWorldLightTableOffset);
	if (table.data is null || table.dims[0]<2 || table.dims[1]<2 || table.dims[2]<2)
		return [0f, 0f, 0f];

	float[3] fraction, inverse;
	int[3] cell;
	foreach(axis; 0..3)
	{
		const float sample_pt=(pos[axis]-table.lookup_start[axis])*table.inv_block_size[axis];
		int c=cast(int)sample_pt;
		// d3d.ren reads the +1 neighbours of the clamped cell unchecked; stay one cell inside so we never read past the table
		if (c<0) c=0;
		else if (c>table.dims_minus_1[axis]-1) c=table.dims_minus_1[axis]-1;
		cell[axis]=c;
		fraction[axis]=sample_pt-floor(sample_pt);
		if (fraction[axis]<0f) fraction[axis]=0f;
		else if (fraction[axis]>1f) fraction[axis]=1f;
		inverse[axis]=1f-fraction[axis];
	}

	LightGridSample* base=table.data+cell[0]+cell[1]*table.dims[0]+cell[2]*table.x_size_times_y_size;
	LightGridSample*[8] samples=[
		base+table.dims[0], base+table.dims[0]+1, base, base+1,
		base+table.x_size_times_y_size+table.dims[0], base+table.x_size_times_y_size+table.dims[0]+1,
		base+table.x_size_times_y_size, base+table.x_size_times_y_size+1
	];

	float[3] result;
	foreach(channel; 0..3)
	{
		float Get(int i) { const LightGridSample* s=samples[i]; return channel==0 ? s.r : channel==1 ? s.g : s.b; }

		float y0=Get(2)*inverse[1]+Get(0)*fraction[1];
		float y1=Get(3)*inverse[1]+Get(1)*fraction[1];
		const float xy0=y0*inverse[0]+y1*fraction[0];
		y0=Get(6)*inverse[1]+Get(4)*fraction[1];
		y1=Get(7)*inverse[1]+Get(5)*fraction[1];
		const float xy1=y0*inverse[0]+y1*fraction[0];
		result[channel]=cast(int)(xy0*inverse[2]+xy1*fraction[2]); // truncated like the original
	}
	return result;
}
