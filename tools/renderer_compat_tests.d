// CPU-only: ldc2 -m32 -Isource tools/renderer_compat_tests.d source/renderer_compat.d
import RendererCompat;
import std.math: abs, sin;
import std.stdio: writeln;
import std.exception: assertThrown;

void main()
{
	// These offsets come from the released RMode, not from the port's declarations.
	static assert(Mode.sizeof==420 && Mode.filename.offsetof==4);
	static assert(Mode.driver_name.offsetof==204 && Mode.display_name.offsetof==304);
	static assert(Mode.width.offsetof==404 && Mode.next.offsetof==416);
	Mode mode;
	mode.is_hardware=1;
	mode.filename[0..9]="d_ren.ren";
	const(ubyte)[] record=(cast(const(ubyte)*)&mode)[0..Mode.sizeof];
	assert(record[0..4]==[1,0,0,0]);
	assert(record[4..13]==cast(const(ubyte)[])"d_ren.ren");

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
