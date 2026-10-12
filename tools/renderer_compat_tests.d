// CPU-only: ldc2 -m32 -Isource tools/renderer_compat_tests.d source/renderer_compat.d
import RendererCompat;
import std.math: abs, sin;
import std.stdio: writeln;
import std.exception: assertThrown;

void main()
{
	// These offsets come from the released RMode, not from the port's declarations.
	static assert(Mode.sizeof==420 && Mode.filename.offsetof==1);
	static assert(Mode.driver_name.offsetof==201 && Mode.display_name.offsetof==301);
	static assert(Mode.width.offsetof==404 && Mode.next.offsetof==416);
	Mode mode;
	mode.is_hardware=1;
	mode.filename[0..9]="d_ren.ren";
	const(ubyte)[] record=(cast(const(ubyte)*)&mode)[0..Mode.sizeof];
	assert(record[0]==1);
	assert(record[1..10]==cast(const(ubyte)[])"d_ren.ren");
	// Decode an independently serialized native record. Client r_InitRender
	// (0x452b7) loads the DLL from mode+1; original enumeration writes names
	// at +0xc9/+0x12d. The numeric fields remain aligned after three pad bytes.
	ubyte[420] native=0;
	native[0]=1;
	native[1..10]=cast(const(ubyte)[])"d_ren.ren";
	native[201..208]=cast(const(ubyte)[])"primary";
	native[301..307]=cast(const(ubyte)[])"Vulkan";
	native[405]=5; native[408]=0xd0; native[409]=2; native[412]=16;
	const Mode* decoded=cast(const Mode*)native.ptr;
	assert(decoded.filename[0..9]=="d_ren.ren" && decoded.filename[9]==0);
	assert(decoded.driver_name[0..7]=="primary" && decoded.driver_name[7]==0);
	assert(decoded.display_name[0..6]=="Vulkan" && decoded.display_name[6]==0);
	assert(decoded.width==1280 && decoded.height==720 && decoded.depth==16 && decoded.next is null);

	ModelWarble warp;
	warp.EndScene(0.02f,25f,0.92f);
	assert(abs(warp.phase-0.5f)<0.00001f);
	// Native table0 is .96; table1 uses the next 32-step sine sample.
	const float expected=0.96f+0.5f*0.04f*cast(float)sin(6.2831855f/32f);
	assert(abs(warp.Scale(0)-expected)<0.00001f);
	assert(warp.Scale(0)==warp.Scale(32));
	warp.EndScene(0.02f,25f,0.92f);
	assert(abs(warp.Scale(0)-(0.96f+0.04f*cast(float)sin(6.2831855f/32f)))<0.00001f);
	warp.EndScene(0f,0f,2f); // only the amplitude clamps, not the base scale
	assert(warp.Scale(0)==2f && warp.Scale(7)==2f);
	warp.EndScene(0f,0f,1f);
	assert(warp.Scale(0)==1f);

	// Two rows of RGBA pixels: red/green above blue/white. BMP is bottom-up BGR.
	ubyte[] rgba=[255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255];
	auto bmp=EncodeScreenshot(2,2,rgba,false);
	assert(bmp.length==70 && bmp[0..2]==[0x42,0x4d] && bmp[10]==54 && bmp[28]==24);
	assert(bmp[54..62]==[255,0,0,255,255,255,0,0]);
	assert(bmp[62..70]==[0,0,255,0,255,0,0,0]);
	ubyte[] bgra=[0,0,255,255, 0,255,0,255, 255,0,0,255, 255,255,255,255];
	assert(EncodeScreenshot(2,2,bgra,true)==bmp);
	auto odd=EncodeScreenshot(1,1,[cast(ubyte)10,20,30,255],false);
	assert(odd.length==58 && odd[54..58]==[30,20,10,0]);
	assertThrown!Exception(EncodeScreenshot(0,1,null,false));
	assertThrown!Exception(EncodeScreenshot(1,2,rgba[0..4],false));
	writeln("renderer compatibility: mode ABI, warble phase/shared vertices, BMP pixels/orientation/padding passed");
}
