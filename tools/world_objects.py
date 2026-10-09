#!/usr/bin/env python3
"""
Lists the objects stored in a LithTech 1 world file (.dat), including the ones the engine never creates at run time
(classes flagged CF_NORUNTIME, such as the static Light, DirLight and GlobalDirLight the lightmaps were baked from).

    world_objects.py <world.dat>                       # object count per class
    world_objects.py <world.dat> --class Light DirLight # those objects with all their properties
    world_objects.py <world.dat> --json out.json        # every object as JSON

Format, from the engine's LoadObjects (blood2_recon recon/engine/DE/MiniServ/S_Object.cpp):
  DWORD version, DWORD object data offset; at that offset DWORD object count, then per object:
  WORD data length, string class name, DWORD property count, then per property:
  string name, BYTE type (PT_*), DWORD flags, WORD length, the value (a string for PT_STRING, else length bytes).
Strings are a WORD length and that many bytes (DStream::ReadString).
"""

import argparse
import collections
import json
import struct
import sys

PT_NAMES = {0: "string", 1: "vector", 2: "colour", 3: "real", 4: "flags", 5: "bool", 6: "longint", 7: "rotation"}


class Reader:
    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos

    def take(self, fmt):
        values = struct.unpack_from("<" + fmt, self.data, self.pos)
        self.pos += struct.calcsize("<" + fmt)
        return values if len(values) > 1 else values[0]

    def string(self):
        n = self.take("H")
        s = self.data[self.pos:self.pos + n].decode("latin-1")
        self.pos += n
        return s


def value_of(kind, raw, reader):
    if kind == 0:
        return reader
    if kind in (1, 2):
        return list(struct.unpack_from("<3f", raw))
    if kind == 3:
        return struct.unpack_from("<f", raw)[0]
    if kind in (4, 6):
        return struct.unpack_from("<I", raw)[0] if len(raw) >= 4 else raw.hex()
    if kind == 5:
        return bool(raw[0]) if raw else False
    if kind == 7:
        return list(struct.unpack_from("<4f", raw))  # quaternion x, y, z, w
    return raw.hex()


def read_objects(path):
    data = open(path, "rb").read()
    r = Reader(data)
    version, offset = r.take("II")
    r.pos = offset
    count = r.take("I")
    objects = []
    for _ in range(count):
        length = r.take("H")
        start = r.pos
        cls = r.string()
        props = {}
        for _ in range(r.take("I")):
            name = r.string()
            kind, flags, plen = r.take("BIH")
            if kind == 0:
                value = r.string()
            else:
                raw = data[r.pos:r.pos + plen]
                r.pos += plen
                value = value_of(kind, raw, None)
            props[name] = value
        objects.append({"class": cls, "properties": props})
        # the stored length covers the object's data; trust the parse but report a mismatch
        if r.pos - start != length:
            print("warning: %s object length %d, parsed %d" % (cls, length, r.pos - start), file=sys.stderr)
    return version, objects


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("world")
    parser.add_argument("--class", dest="classes", nargs="+")
    parser.add_argument("--json")
    args = parser.parse_args()

    version, objects = read_objects(args.world)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"version": version, "objects": objects}, f, indent=1)
    if args.classes:
        wanted = {c.lower() for c in args.classes}
        for o in objects:
            if o["class"].lower() in wanted:
                print(o["class"], json.dumps(o["properties"]))
        return
    print("version %d, %d objects" % (version, len(objects)))
    for cls, n in collections.Counter(o["class"] for o in objects).most_common():
        print("  %5d  %s" % (n, cls))


if __name__ == "__main__":
    sys.exit(main())
