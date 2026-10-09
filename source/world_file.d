module WorldFile;

/+
 + The game's own files, read the way the engine finds them: through the `-rez` sources on the command line (archives or
 + folders), a later source overriding an earlier one. Used for the static lights of the loaded world: the editor's
 + Light, DirLight, ObjectLight and GlobalDirLight objects are CF_NORUNTIME, so the engine reads them from the world file
 + and skips them (blood2_recon S_Object.cpp LoadObjects), and only the world file still has them.
 +
 + REZ format (blood2_recon gh_nolf2 tools/rezlist.py, from rezmgr.cpp): a 127-byte text header, then DWORDs
 + version, root directory position, root directory size, ... A directory is a run of entries: DWORD type (1 directory,
 + 0 resource); a directory has DWORD position, size, time and a NUL-terminated name; a resource has DWORD position,
 + size, time, id, type (four characters, reversed: the extension) and key count, a NUL-terminated name and comment, and
 + the keys.
 +/

import std.stdio: File;

struct StaticLight
{
	enum Kind : ubyte { Point, Spot, ObjectOnly, Directional }
	Kind kind;
	float[3] pos=[0f, 0f, 0f];
	float[3] colour=[255f, 255f, 255f]; // 0..255 at the light (LightColor / InnerColor)
	float[3] outer=[0f, 0f, 0f]; // 0..255 at the radius
	float radius=300f;
	float bright_scale=1f;
	float[3] rotation=[0f, 0f, 0f]; // Euler angles in radians (pitch, yaw, roll), as GetPropRotation reads them
	float fov=90f; // spots: the cone's full angle in degrees
	bool clip=true; // ClipLight: geometry shadowed it in the bake
	bool light_objects=true; // LightObjects: it lit models (the light grid)
}

// a file inside an archive or folder: its bytes start at `base`
struct GameFile
{
	File file;
	ulong base, size;

	bool valid() const { return file.isOpen; }

	ubyte[] Read(ulong offset, size_t length)
	{
		if (offset>=size)
			return null;
		if (offset+length>size)
			length=cast(size_t)(size-offset);
		ubyte[] buffer=new ubyte[length];
		file.seek(cast(long)(base+offset));
		return file.rawRead(buffer);
	}
}

// the command line's -rez sources in order (archives or folders, relative to the game folder)
string[] RezSources()
{
	import core.sys.windows.winbase: GetCommandLineA;
	import std.string: fromStringz, toLower;

	string[] tokens;
	string current;
	bool quoted, any;
	foreach(char c; GetCommandLineA().fromStringz)
	{
		if (c=='"')
		{
			quoted=!quoted;
			any=true;
		}
		else if ((c==' ' || c=='\t') && !quoted)
		{
			if (any)
				tokens~=current;
			current=null;
			any=false;
		}
		else
		{
			current~=c;
			any=true;
		}
	}
	if (any)
		tokens~=current;

	string[] sources;
	foreach(i, token; tokens)
		if (token.toLower=="-rez" && i+1<tokens.length)
			sources~=tokens[i+1];
	return sources;
}

// a file by its game path (e.g. "Worlds\04_steamtunnels.dat"), from the last source that has it
GameFile OpenGameFile(string name)
{
	import std.file: exists, isDir, getSize;
	import std.string: toUpper, replace;

	const string key=name.replace("/", "\\").toUpper;
	string[] sources=RezSources();
	foreach_reverse(source; sources)
	{
		try
		{
			if (!exists(source))
				continue;
			if (isDir(source))
			{
				const string path=source~"\\"~name;
				if (exists(path) && !isDir(path))
					return GameFile(File(path, "rb"), 0, getSize(path));
				continue;
			}
			if (const RezEntry* entry=key in RezIndex(source))
				return GameFile(File(source, "rb"), entry.position, entry.size);
		}
		catch (Exception)
			continue;
	}
	return GameFile.init;
}

private struct RezEntry { ulong position, size; }
private __gshared RezEntry[string][string] _rez_indexes; // archive path -> upper-case "DIR\NAME.EXT" -> entry

private RezEntry[string] RezIndex(string archive)
{
	if (auto index=archive in _rez_indexes)
		return *index;

	RezEntry[string] index;
	auto file=File(archive, "rb");
	ubyte[40] header;
	file.seek(127);
	file.rawRead(header[]);
	const uint root_position=*cast(uint*)&header[4], root_size=*cast(uint*)&header[8];

	void Walk(uint position, uint size, string prefix, int depth)
	{
		import std.string: toUpper;
		if (depth>16 || size==0 || size>64*1024*1024)
			return;
		ubyte[] data=new ubyte[size];
		file.seek(position);
		data=file.rawRead(data);
		size_t at=0;

		uint Dword()
		{
			if (at+4>data.length)
				throw new Exception("truncated directory in "~archive);
			const uint v=*cast(uint*)(data.ptr+at);
			at+=4;
			return v;
		}
		string CString()
		{
			const size_t start=at;
			while (at<data.length && data[at]!=0)
				at++;
			const string s=cast(string)data[start..at].idup;
			at++;
			return s;
		}

		while (at<data.length)
		{
			const uint type=Dword();
			if (type==1)
			{
				const uint dir_position=Dword(), dir_size=Dword();
				Dword(); // time
				const string name=CString();
				Walk(dir_position, dir_size, prefix~name.toUpper~"\\", depth+1);
			}
			else if (type==0)
			{
				const uint res_position=Dword(), res_size=Dword();
				Dword(); // time
				Dword(); // id
				const uint fourcc=Dword(), keys=Dword();
				const string name=CString();
				CString(); // comment
				at+=4*keys;
				char[4] ext=[cast(char)(fourcc >> 24), cast(char)(fourcc >> 16), cast(char)(fourcc >> 8), cast(char)fourcc];
				string extension;
				foreach(c; ext)
					if (c>' ')
						extension~=c;
				index[prefix~name.toUpper~(extension.length ? "."~extension.toUpper : "")]=RezEntry(res_position, res_size);
			}
			else
				break; // out of step
		}
	}

	Walk(root_position, root_size, "", 0);
	_rez_indexes[archive]=index;
	return index;
}

// The static lights in a world file's object section (format: blood2_recon S_Object.cpp LoadObjects, see
// tools/world_objects.py): DWORD version, DWORD object section offset; there DWORD object count, then per object
// WORD length, class name, DWORD property count, and per property name, BYTE type, DWORD flags, WORD length, value.
// Strings are a WORD length and the characters.
StaticLight[] ReadStaticLights(ref GameFile world)
{
	ubyte[] head=world.Read(0, 8);
	if (head.length<8)
		return null;
	const uint offset=*cast(uint*)&head[4];
	ubyte[] data=world.Read(offset, cast(size_t)(world.size-offset));
	size_t at=0;

	T Take(T)()
	{
		if (at+T.sizeof>data.length)
			throw new Exception("world file object section truncated");
		const T v=*cast(T*)(data.ptr+at);
		at+=T.sizeof;
		return v;
	}
	string Str()
	{
		const ushort length=Take!ushort();
		if (at+length>data.length)
			throw new Exception("world file string truncated");
		const string s=cast(string)data[at..at+length].idup;
		at+=length;
		return s;
	}

	StaticLight[] lights;
	const uint count=Take!uint();
	foreach(object; 0..count)
	{
		const ushort length=Take!ushort();
		const size_t start=at;
		const string class_name=Str();

		StaticLight light;
		bool wanted=true;
		switch(class_name)
		{
			case "Light": light.kind=StaticLight.Kind.Point; break;
			case "DirLight": light.kind=StaticLight.Kind.Spot; break;
			case "ObjectLight": light.kind=StaticLight.Kind.ObjectOnly; break;
			case "GlobalDirLight": light.kind=StaticLight.Kind.Directional; break;
			default: wanted=false;
		}

		const uint properties=Take!uint();
		foreach(p; 0..properties)
		{
			const string name=Str();
			const ubyte type=Take!ubyte();
			Take!uint(); // flags
			const ushort value_length=Take!ushort();
			if (type==0) // PT_STRING
			{
				Str();
				continue;
			}
			if (at+value_length>data.length)
				throw new Exception("world file property truncated");
			const(ubyte)[] value=data[at..at+value_length];
			at+=value_length;
			if (!wanted)
				continue;

			float F(size_t i) { return value.length>=(i+1)*4 ? *cast(float*)(value.ptr+i*4) : 0f; }
			float[3] V() { return [F(0), F(1), F(2)]; }
			switch(name)
			{
				case "Pos": light.pos=V(); break;
				case "LightColor", "InnerColor": light.colour=V(); break;
				case "OuterColor": light.outer=V(); break;
				case "LightRadius": light.radius=F(0); break;
				case "BrightScale": light.bright_scale=F(0); break;
				case "Rotation": light.rotation=V(); break;
				case "FOV": light.fov=F(0); break;
				case "ClipLight": light.clip=value.length && value[0]!=0; break;
				case "LightObjects": light.light_objects=value.length && value[0]!=0; break;
				default: break;
			}
		}
		// the stored length is authoritative
		at=start+length;
		if (wanted)
			lights~=light;
	}
	return lights;
}
