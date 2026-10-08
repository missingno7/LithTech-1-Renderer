module vk.Surface;

struct ImageSurface
{
	bool is_locked;
	int width, height, bpp, stride;
	ubyte[] pixels;

	this(uint w, uint h)
	{
		is_locked=false;

		width=w;
		height=h;
		bpp=2; // hardcoded since we /know/ LT1 only blits in 16-bit (555 or 565)
		stride=w*bpp;

		pixels=new ubyte[stride*height];
	}

	@property ushort[] Pixels16() { return cast(ushort[])pixels; }

	// the engine only keeps raw pointers to surfaces, so they live outside the GC heap
	static ImageSurface* Create(int w, int h)
	{
		import core.stdc.stdlib: calloc;

		ImageSurface* surface=cast(ImageSurface*)calloc(1, ImageSurface.sizeof);
		surface.width=w;
		surface.height=h;
		surface.bpp=2;
		surface.stride=w*surface.bpp;
		surface.pixels=(cast(ubyte*)calloc(surface.stride*h, 1))[0..surface.stride*h];
		return surface;
	}

	static void Free(ImageSurface* surface)
	{
		import core.stdc.stdlib: free;

		if (surface is null)
			return;

		free(surface.pixels.ptr);
		free(surface);
	}
}
