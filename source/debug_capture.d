module DebugCapture;

/+
 + Debug captures and the renderer's command file, for testing without touching the game window.
 +
 + While the game runs, d_ren polls `d_ren_cmd.txt` in the game folder (a few times a second). Each line is run as a
 + console command (e.g. `load worlds\04_steamtunnels`, `d_Lighting 1`), except
 +
 +     capture <name> [<label>:<key>=<value>,<key>=<value>... ...]
 +
 + which renders the next 3D frame again once per variant into an offscreen image and writes, to `captures\` in the
 + game folder, `<name>_<label>.png` per variant, `<name>_depth.f32` (the scene's depth, float per pixel) and
 + `<name>.json`: camera, projection, settings, the light list, per-variant GPU times, and for the ids seen in "id"
 + views what drew them. The presented frame is untouched. Without variants (and from the game console with
 + `d_Capture <name>`) the default set is: the frame as shown, d3d.ren's lighting, the modern lighting, and the light
 + and id views.
 +
 + Variant keys: view (final, light, dynamic, normal, id, specular, lights), lighting, specular, falloff, aa,
 + compare, hud (final views only). tools/analyze_capture.py decodes the views.
 +/

import std.conv: to;
import std.string: strip, split, indexOf, toLower;

enum DebugView : uint { Final, Light, Dynamic, Normal, Id, Specular, Lights } // lighting.glsl DEBUG_VIEW_*

// one rendering of the captured frame
struct CaptureVariant
{
	string label;
	DebugView view;
	string[2][] settings; // key, value: applied over the current settings for this variant only
	bool hud;
}

struct CaptureRequest
{
	string name;
	CaptureVariant[] variants;
}

// draw ids in the id view: world polygons are their index + 1, object batches IdObjectBase + their index in draw order
enum uint IdObjectBase=0x800000;

// `capture <name> [label:key=value,... ...]`; null when the line isn't a capture
CaptureRequest* ParseCapture(string line)
{
	string[] words=line.strip.split;
	if (words.length<2 || words[0].toLower!="capture")
		return null;

	auto request=new CaptureRequest;
	foreach(c; words[1])
		if (!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-'))
			return null; // it becomes a file name
	request.name=words[1];

	if (words.length==2)
	{
		// the frame as shown (with the 2D layer), d3d.ren's lighting against the modern one, the light term and the ids;
		// other views on request
		request.variants~=CaptureVariant("shown", DebugView.Final, null, true);
		request.variants~=CaptureVariant("classic", DebugView.Final, [["lighting", "0"], ["aa", "0"]], false);
		request.variants~=CaptureVariant("modern", DebugView.Final, [["lighting", "1"]], false);
		foreach(view; [DebugView.Light, DebugView.Id])
			request.variants~=CaptureVariant(ViewName(view), view, null, false);
		return request;
	}

	foreach(word; words[2..$])
	{
		CaptureVariant variant;
		const ptrdiff_t colon=word.indexOf(':');
		variant.label=colon>0 ? word[0..colon] : word;
		foreach(c; variant.label)
			if (!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-'))
				return null;
		if (colon>0)
			foreach(setting; word[colon+1..$].split(','))
			{
				const ptrdiff_t equals=setting.indexOf('=');
				if (equals<=0)
					continue;
				const string key=setting[0..equals].toLower, value=setting[equals+1..$];
				if (key=="view")
				{
					foreach(view; DebugView.min..DebugView.max+1)
						if (ViewName(cast(DebugView)view)==value.toLower)
							variant.view=cast(DebugView)view;
				}
				else if (key=="hud")
					variant.hud=value!="0";
				else
					variant.settings~=[key, value];
			}
		request.variants~=variant;
	}
	return request;
}

string ViewName(DebugView view)
{
	static immutable string[] names=["final", "light", "dynamic", "normal", "id", "specular", "lights"];
	return names[view];
}

// reads and deletes the command file; the lines, or nothing
string[] PollCommandFile(string path)
{
	import std.file: exists, readText, remove;
	try
	{
		if (!exists(path))
			return null;
		string text=readText(path);
		remove(path);
		string[] lines;
		foreach(line; text.split('\n'))
			if (line.strip.length)
				lines~=line.strip;
		return lines;
	}
	catch (Exception)
		return null; // still being written, try again later
}

// 8-bit RGB PNG of an RGBA / BGRA image (alpha dropped: the captures are opaque). The game is a 32-bit process, so the
// big buffers are malloc'd and freed at once (a 4K capture through the GC heap ran it out of address space), and zlib
// runs at its fastest level.
void WritePng(string path, uint width, uint height, const(ubyte)[] pixels, bool bgra)
{
	import core.stdc.stdlib: malloc, free;
	import core.stdc.stdio: fopen, fwrite, fclose, FILE;
	import std.string: toStringz;
	import etc.c.zlib: compress2, compressBound, crc32, Z_OK;

	const size_t row=width*3+1, raw_size=row*height;
	ubyte* raw=cast(ubyte*)malloc(raw_size);
	if (raw is null)
		throw new Exception("out of memory for "~path);
	scope(exit) free(raw);
	foreach(y; 0..height)
	{
		ubyte* out_row=raw+y*row;
		out_row[0]=0; // filter: none
		const(ubyte)* in_row=pixels.ptr+cast(size_t)y*width*4;
		foreach(x; 0..width)
		{
			out_row[1+x*3]=in_row[x*4+(bgra ? 2 : 0)];
			out_row[2+x*3]=in_row[x*4+1];
			out_row[3+x*3]=in_row[x*4+(bgra ? 0 : 2)];
		}
	}

	uint compressed_size=cast(uint)compressBound(cast(uint)raw_size);
	ubyte* compressed=cast(ubyte*)malloc(compressed_size);
	if (compressed is null)
		throw new Exception("out of memory for "~path);
	scope(exit) free(compressed);
	if (compress2(compressed, &compressed_size, raw, cast(uint)raw_size, 1)!=Z_OK)
		throw new Exception("compression failed for "~path);

	FILE* file=fopen(path.toStringz, "wb");
	if (file is null)
		throw new Exception("can't write "~path);
	scope(exit) fclose(file);

	static void BigEndian(ubyte* p, uint v) { p[0]=cast(ubyte)(v >> 24); p[1]=cast(ubyte)(v >> 16); p[2]=cast(ubyte)(v >> 8); p[3]=cast(ubyte)v; }
	void Chunk(string type, const(ubyte)* data, uint length)
	{
		ubyte[4] word;
		BigEndian(word.ptr, length);
		fwrite(word.ptr, 1, 4, file);
		fwrite(type.ptr, 1, 4, file);
		if (length)
			fwrite(data, 1, length, file);
		uint crc=crc32(0, cast(const(ubyte)*)type.ptr, 4);
		if (length)
			crc=crc32(crc, data, length);
		BigEndian(word.ptr, crc);
		fwrite(word.ptr, 1, 4, file);
	}

	static immutable ubyte[8] signature=[0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];
	fwrite(signature.ptr, 1, 8, file);
	ubyte[13] header;
	BigEndian(header.ptr, width);
	BigEndian(header.ptr+4, height);
	header[8..13]=[8, 2, 0, 0, 0];
	Chunk("IHDR", header.ptr, 13);
	Chunk("IDAT", compressed, compressed_size);
	Chunk("IEND", null, 0);
}

// raw bytes to a file, without copies
void WriteRaw(string path, const(ubyte)[] bytes)
{
	import core.stdc.stdio: fopen, fwrite, fclose, FILE;
	import std.string: toStringz;
	FILE* file=fopen(path.toStringz, "wb");
	if (file is null)
		throw new Exception("can't write "~path);
	fwrite(bytes.ptr, 1, bytes.length, file);
	fclose(file);
}

// the 24-bit ids seen in an id view: a bit per possible id (2 MiB, malloc'd and reused)
struct IdSet
{
	private uint* bits;

	void Clear()
	{
		import core.stdc.stdlib: calloc;
		import core.stdc.string: memset;
		if (bits is null)
			bits=cast(uint*)calloc(1 << 19, 4);
		else
			memset(bits, 0, (1 << 19)*4);
	}

	void Add(uint id) { bits[(id >> 5) & 0x7FFFF] |= 1u << (id & 31); }

	uint[] Ids()
	{
		uint[] ids;
		if (bits is null)
			return ids;
		foreach(word; 0..(1 << 19))
			if (bits[word])
				foreach(bit; 0..32)
					if (bits[word] & (1u << bit))
						ids~=cast(uint)(word*32+bit);
		return ids;
	}
}

// JSON string escaping for the capture description
string JsonString(const(char)[] text)
{
	string result="\"";
	foreach(char c; text)
	{
		if (c=='"' || c=='\\')
			result~='\\';
		if (c<0x20)
			continue;
		result~=c;
	}
	return result~"\"";
}

string JsonFloats(const float[] values)
{
	import std.format: format;
	string result="[";
	foreach(i, value; values)
		result~=(i ? ", " : "")~format("%.6g", value);
	return result~"]";
}
