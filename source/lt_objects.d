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
	ModelTint=0x4,
	ReallyClose=0x40,
	NoLight=0x200,
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

// d3d.ren 0x3e1d0 / quat_ConvertToMatrix; q is x, y, z, w
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
