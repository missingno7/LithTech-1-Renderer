module RendererCompat;

// Released RMode and exact-matched d3d_EnumModesCallback (0x15d10).
struct Mode
{
	int is_hardware;
	char[200] filename;
	char[100] driver_name;
	char[100] display_name;
	int width, height;
	uint depth;
	Mode* next;
	static assert(is_hardware.sizeof==4 && filename.offsetof==4);
	static assert(driver_name.offsetof==0xcc && display_name.offsetof==0x130);
	static assert(width.offsetof==0x194 && height.offsetof==0x198 && depth.offsetof==0x19c);
	static assert(next.offsetof==0x1a0 && Mode.sizeof==0x1a4);
}

// d3d_ResetModelWarble / d3d_TransformModelVertWarble (0x10cd0 / 0x10d10).
// Table construction follows r_SetupWarbleTable (0x12a60); phase advances at
// the end of each RenderScene, like the exact-matched driver at 0x19970.
struct ModelWarble
{
	float[32] base=0f, delta=0f;
	float phase=0f;
	float table_scale=float.nan;

	void EndScene(float frame_time, float speed, float scale)
	{
		import std.math: sin;
		import std.algorithm: clamp;
		if (scale!=table_scale)
		{
			table_scale=scale;
			const float amplitude=(1f-clamp(scale,0f,1f))*0.5f;
			foreach(i; 0..32) base[i]=amplitude*cast(float)sin((i*0.03125f)*6.2831855f)+(scale+amplitude);
			foreach(i; 0..32) delta[i]=base[(i+1)&31]-base[i];
		}
		phase+=speed*frame_time;
	}

	float Scale(uint vertex) const
	{
		import std.math: floor;
		const uint index=(cast(uint)cast(int)phase+vertex)&31;
		return delta[index]*(phase-cast(float)floor(phase))+base[index];
	}
}

// Original screenshot callback (0x1f140): 24-bit, bottom-up BGR BMP at the
// requested filename. Pad arbitrary-width rows to the BMP-required alignment.
ubyte[] EncodeScreenshot(uint width, uint height, const(ubyte)[] pixels, bool bgra)
{
	import std.exception: enforce;
	enforce(width && height && cast(ulong)width*height*4==pixels.length, "invalid screenshot pixels");
	const ulong stride=(cast(ulong)width*3+3)&~3UL;
	const ulong bytes=54+stride*height;
	enforce(bytes<=uint.max && bytes<=size_t.max, "screenshot is too large");
	ubyte[] bmp=new ubyte[cast(size_t)bytes];
	void Word(size_t at, ushort v) { bmp[at]=cast(ubyte)v; bmp[at+1]=cast(ubyte)(v>>8); }
	void Dword(size_t at, uint v) { foreach(i; 0..4) bmp[at+i]=cast(ubyte)(v>>(i*8)); }
	Word(0,0x4d42); Dword(2,cast(uint)bytes); Dword(10,54); Dword(14,40);
	Dword(18,width); Dword(22,height); Word(26,1); Word(28,24); Dword(34,cast(uint)(stride*height));
	foreach(y; 0..height)
		foreach(x; 0..width)
		{
			const size_t src=(cast(size_t)(height-1-y)*width+x)*4;
			const size_t dst=54+cast(size_t)(stride*y)+x*3;
			bmp[dst]=pixels[src+(bgra ? 0 : 2)];
			bmp[dst+1]=pixels[src+1];
			bmp[dst+2]=pixels[src+(bgra ? 2 : 0)];
		}
	return bmp;
}
