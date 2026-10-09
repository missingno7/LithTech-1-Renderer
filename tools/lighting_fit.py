#!/usr/bin/env python3
"""
Compares a level's lightmaps (d_ren's d_DumpLighting output) with the static lights stored in its world file
(tools/world_objects.py), to find how the lighting preprocessor baked them.

    lighting_fit.py <world>_lighting.bin <world>.dat [--light N]

For every lightmap texel it computes the world position (from the polygon's lightmap axes) and keeps the texels inside
their polygon. Texels within reach of exactly one light isolate that light's contribution; their brightness relative
to the light's colour is tabulated against distance / radius and N.L, which shows the falloff shape, whether N.L
applies, and the scale. Shadowed texels (ClipLight) show up as outliers near zero.
"""

import argparse
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from world_objects import read_objects  # noqa: E402


def read_dump(path):
    data = open(path, "rb").read()
    if data[:4] != b"DRLM":
        raise SystemExit("not a d_DumpLighting file")
    version, count = struct.unpack_from("<II", data, 4)
    pos = 12
    polygons = []
    for _ in range(count):
        index, flags = struct.unpack_from("<II", data, pos); pos += 8
        plane = struct.unpack_from("<4f", data, pos); pos += 16
        origin = struct.unpack_from("<3f", data, pos); pos += 12
        u_axis = struct.unpack_from("<3f", data, pos); pos += 12
        v_axis = struct.unpack_from("<3f", data, pos); pos += 12
        (nverts,) = struct.unpack_from("<I", data, pos); pos += 4
        verts = np.array(struct.unpack_from("<%df" % (3 * nverts), data, pos), dtype=np.float64).reshape(nverts, 3)
        pos += 12 * nverts
        w, h = struct.unpack_from("<HH", data, pos); pos += 4
        texels = np.frombuffer(data, dtype="<u2", count=w * h, offset=pos).reshape(h, w)
        pos += 2 * w * h
        polygons.append(dict(index=index, flags=flags, normal=np.array(plane[:3]), distance=plane[3],
                             origin=np.array(origin), u=np.array(u_axis), v=np.array(v_axis), verts=verts,
                             w=w, h=h, texels=texels))
    return polygons


def rgb565(t):
    """As d3d.ren expands them: shifted, no bit replication; 0..1."""
    r = ((t >> 11) & 0x1F) << 3
    g = ((t >> 5) & 0x3F) << 2
    b = (t & 0x1F) << 3
    return np.stack([r, g, b], axis=-1) / 255.0


def texel_samples(poly):
    """World positions, normal and colours of the texels whose centre lies inside the polygon."""
    n, u, v, o = poly["normal"], poly["u"], poly["v"], poly["origin"]
    m = np.array([n, u, v])
    if abs(np.linalg.det(m)) < 1e-6:
        return None
    inv = np.linalg.inv(m)
    jj, ii = np.mgrid[0:poly["h"], 0:poly["w"]]
    rhs = np.stack([np.full(ii.shape, poly["distance"]), 20.0 * ii + u @ o, 20.0 * jj + v @ o], axis=-1)
    points = rhs @ inv.T
    # inside the (convex) polygon, with a little slack for texels on the edge
    verts = poly["verts"]
    inside = np.ones(ii.shape, dtype=bool)
    for k in range(len(verts)):
        a, b = verts[k], verts[(k + 1) % len(verts)]
        edge_normal = np.cross(n, b - a)
        if np.linalg.norm(edge_normal) < 1e-6:
            continue
        side = (points - a) @ edge_normal
        centre_side = (verts.mean(axis=0) - a) @ edge_normal
        inside &= side * np.sign(centre_side) > -10.0 * np.linalg.norm(edge_normal)
    colours = rgb565(poly["texels"].astype(np.uint32))
    return points[inside], colours[inside]


def lights_from(objects):
    lights = []
    for o in objects:
        p = o["properties"]
        if o["class"] not in ("Light", "DirLight") or "Pos" not in p:
            continue
        inner = p.get("LightColor", p.get("InnerColor"))
        lights.append(dict(kind=o["class"], pos=np.array(p["Pos"]), radius=p.get("LightRadius", 300.0),
                           inner=np.array(inner) / 255.0, outer=np.array(p.get("OuterColor", [0, 0, 0])) / 255.0,
                           scale=p.get("BrightScale", 1.0), clip=p.get("ClipLight", True),
                           rotation=p.get("Rotation"), fov=p.get("FOV")))
    return lights


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dump")
    parser.add_argument("world")
    args = parser.parse_args()

    polygons = read_dump(args.dump)
    _, objects = read_objects(args.world)
    lights = lights_from(objects)
    print("%d lightmapped polygons, %d point lights, %d spot lights" % (len(polygons),
        sum(l["kind"] == "Light" for l in lights), sum(l["kind"] == "DirLight" for l in lights)))
    positions = np.array([l["pos"] for l in lights])
    radii = np.array([l["radius"] for l in lights])

    samples = []
    for poly in polygons:
        s = texel_samples(poly)
        if s is not None and len(s[0]):
            d = np.linalg.norm(positions[None] - s[0][:, None], axis=-1)
            samples.append((poly, s[0], s[1], d, d < radii[None]))
    print("%d texels inside their polygons" % sum(len(x[1]) for x in samples))

    # the ambient: texels no light (point or spot) reaches have one value per level
    unlit = np.concatenate([colours[reach.sum(axis=1) == 0] for _, _, colours, _, reach in samples])
    ambient = np.median(unlit, axis=0) if len(unlit) else np.zeros(3)
    print("ambient (%d texels no light reaches): %s / 255" % (len(unlit), np.round(ambient * 255).astype(int)))

    # texels reached by exactly one point light: (texel - ambient) / (colour * BrightScale) in the light's strongest
    # channel, unsaturated texels only
    rows = []  # d/r, N.L, relative brightness
    for poly, points, colours, d, reach in samples:
        for k in np.nonzero(reach.sum(axis=1) == 1)[0]:
            li = int(np.nonzero(reach[k])[0][0])
            light = lights[li]
            if light["kind"] != "Light":
                continue
            colour = light["inner"] * light["scale"]
            c = int(np.argmax(colour))
            if colour[c] < 0.1 or colours[k][c] >= 0.95:
                continue
            ndl = float((light["pos"] - points[k]) @ poly["normal"]) / max(d[k, li], 1e-6)
            rows.append((d[k, li] / radii[li], ndl, (colours[k][c] - ambient[c]) / colour[c]))
    print("%d texels lit by exactly one point light" % len(rows))
    if not rows:
        return
    a = np.array(rows)

    d_bins = np.linspace(0, 1, 11)
    n_bins = [-1.0, 0.0, 0.25, 0.5, 0.75, 1.01]
    print("\nmedian (texel - ambient) / light colour (count), by distance / radius (rows) and N.L (columns)")
    print("  d/r    " + "  ".join("%-14s" % ("%.2f..%.2f" % (n_bins[j], n_bins[j + 1])) for j in range(len(n_bins) - 1)))
    for i in range(len(d_bins) - 1):
        line = "  %.1f-%.1f" % (d_bins[i], d_bins[i + 1])
        for j in range(len(n_bins) - 1):
            m = (a[:, 0] >= d_bins[i]) & (a[:, 0] < d_bins[i + 1]) & (a[:, 1] >= n_bins[j]) & (a[:, 1] < n_bins[j + 1])
            line += "  %6.3f (%5d)" % (np.median(a[m, 2]), m.sum()) if m.sum() >= 5 else "  %-14s" % "-"
        print(line)

    # candidate falloffs on the facing texels the bake didn't shadow, one scale each (median ratio)
    facing = a[a[:, 1] > 0.0]
    x, y = facing[:, 0], facing[:, 2]
    lit = y > 0.05
    print("\ncandidate falloffs on %d facing texels (%.0f%% read as shadowed and are left out):" % (len(y), 100 * np.mean(~lit)))
    for name, f in {"1 - d/r": 1 - x, "1 - (d/r)^2": 1 - x * x, "(1 - d/r)^2": (1 - x) ** 2, "(1 - d/r)^1.5": (1 - x) ** 1.5}.items():
        k = float(np.median(y[lit] / np.maximum(f[lit], 1e-3)))
        print("  %-14s scale %.3f  mean abs error %.4f" % (name, k, np.mean(np.abs(k * f[lit] - y[lit]))))


if __name__ == "__main__":
    sys.exit(main())
