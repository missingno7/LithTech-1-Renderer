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
 + views what drew them. The presented frame is untouched. Without variants the default set is the final image plus
 + the light, dynamic, normal and id views with the current settings.
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
		foreach(view; [DebugView.Final, DebugView.Light, DebugView.Dynamic, DebugView.Normal, DebugView.Id])
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

// 8-bit RGBA PNG (alpha dropped: the captures are opaque); bgra for B8G8R8A8 images
void WritePng(string path, uint width, uint height, const(ubyte)[] pixels, bool bgra)
{
	import std.zlib: compress;
	import std.digest.crc: crc32Of;
	import std.bitmanip: nativeToBigEndian;
	import std.file: write;

	ubyte[] raw=new ubyte[(width*3+1)*height];
	size_t o=0;
	foreach(y; 0..height)
	{
		raw[o++]=0; // filter: none
		foreach(x; 0..width)
		{
			const size_t i=(y*width+x)*4;
			raw[o++]=pixels[i+(bgra ? 2 : 0)];
			raw[o++]=pixels[i+1];
			raw[o++]=pixels[i+(bgra ? 0 : 2)];
		}
	}

	ubyte[] png=[0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];
	void Chunk(string type, const(ubyte)[] data)
	{
		png~=nativeToBigEndian(cast(uint)data.length)[];
		const(ubyte)[] typed=cast(const(ubyte)[])type~data;
		png~=typed;
		auto crc=crc32Of(typed); // little-endian bytes of the CRC
		png~=[crc[3], crc[2], crc[1], crc[0]];
	}
	ubyte[] header=nativeToBigEndian(width)[]~nativeToBigEndian(height)[]~cast(ubyte[])[8, 2, 0, 0, 0];
	Chunk("IHDR", header);
	Chunk("IDAT", cast(const(ubyte)[])compress(raw, 6));
	Chunk("IEND", null);
	write(path, png);
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
