#!/usr/bin/env python3
"""
Reads a d_ren debug capture (captures/<name>.json plus its images and depth, see source/debug_capture.d) and answers
questions about it with numbers instead of screenshots.

    analyze_capture.py <captures dir> <name>                      # summary: what's on screen, the crosshair
    analyze_capture.py <captures dir> <name> --at X Y             # one pixel: what drew it, its light terms, the lights
    analyze_capture.py <captures dir> <name> --surfaces           # every id: coverage and mean light terms
    analyze_capture.py <captures dir> <name> --diff A B           # variants A and B: per-surface luminance change

Views are decoded as lighting.glsl encodes them: light 0..1, dynamic byte 128 + 63.75 d, normal n/2 + 0.5, id 24-bit rgb.
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.299, 0.587, 0.114])


class Capture:
    def __init__(self, folder, name):
        self.folder = folder
        with open(os.path.join(folder, name + ".json")) as f:
            self.meta = json.load(f)
        self.width = self.meta["width"]
        self.height = self.meta["height"]
        self.variants = {v["label"]: v for v in self.meta["variants"]}
        self._images = {}
        self.depth = None
        if self.meta.get("depth"):
            raw = np.fromfile(os.path.join(folder, self.meta["depth"]["file"]), dtype=np.float32)
            self.depth = raw.reshape(self.height, self.width)
        self.view = np.array(self.meta["matrices"]["view"], dtype=np.float64).reshape(4, 4).T
        self.proj = np.array(self.meta["matrices"]["proj"], dtype=np.float64).reshape(4, 4).T

    def image(self, label):
        if label not in self._images:
            path = os.path.join(self.folder, self.variants[label]["file"])
            self._images[label] = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
        return self._images[label]

    def label_of_view(self, view):
        for label, v in self.variants.items():
            if v["view"] == view and not v["settings"]:
                return label
        for label, v in self.variants.items():
            if v["view"] == view:
                return label
        return None

    def ids(self):
        label = self.label_of_view("id")
        if label is None:
            return None
        rgb = np.asarray(Image.open(os.path.join(self.folder, self.variants[label]["file"])).convert("RGB"), dtype=np.uint32)
        return rgb[..., 0] | (rgb[..., 1] << 8) | (rgb[..., 2] << 16)

    def decoded(self, view, label=None):
        label = label or self.label_of_view(view)
        if label is None:
            return None
        img = self.image(label)
        if view == "dynamic":
            return (img * 255.0 - 128.0) / 63.75
        if view == "normal":
            return img * 2.0 - 1.0
        if view == "lights":
            return img[..., :2] * 40.0
        return img

    def world_position(self, x, y):
        """World position of pixel (x, y) from the depth and the matrices."""
        if self.depth is None:
            return None
        d = float(self.depth[y, x])
        if d >= 1.0:
            return None
        vx, vy, vw, vh = self.meta["viewport"]
        ndc = np.array([(x + 0.5 - vx) / vw * 2 - 1, (y + 0.5 - vy) / vh * 2 - 1, d, 1.0])
        inv = np.linalg.inv(self.proj @ self.view)
        p = inv @ ndc
        return p[:3] / p[3]

    def describe(self, id_):
        entry = self.meta["ids"].get(str(int(id_)))
        if entry is None:
            return "id %d (not described)" % id_
        if entry["kind"] == "world":
            return "world polygon %d, texture %s, surface flags %s%s%s" % (
                entry["polygon"], entry["texture"] or "?", entry["surface_flags"],
                ", lightmapped" if entry["lightmapped"] else ", pre-lit", ", fullbright" if entry["fullbright"] else "")
        if entry["kind"] == "object":
            src = entry["source"]
            what = "%s at %s" % (src["type"], fmt(src["position"])) if src else "no object"
            return "object batch: %s (%s, %s, %s, lighting %s, %d vertices)" % (
                what, entry["group"], entry["pipe"], entry["mode"], entry["lighting"], entry["vertices"])
        return entry["kind"]


def fmt(v, digits=1):
    return "(" + ", ".join("%.*f" % (digits, c) for c in v) + ")"


def crosshair(cap):
    vx, vy, vw, vh = cap.meta["viewport"]
    return int(vx + vw / 2), int(vy + vh / 2)


def report_pixel(cap, x, y):
    print("pixel (%d, %d)" % (x, y))
    ids = cap.ids()
    if ids is not None:
        print("  drawn by:", cap.describe(ids[y, x]))
    for view in ("final", "light", "dynamic", "specular"):
        values = cap.decoded(view)
        if values is not None:
            print("  %-8s %s" % (view, fmt(values[y, x], 3)))
    normal = cap.decoded("normal")
    if normal is not None:
        print("  normal   %s" % fmt(normal[y, x], 3))
    p = cap.world_position(x, y)
    if p is None:
        print("  no depth there")
        return
    eye = np.array(cap.meta["camera"]["position"])
    print("  world    %s, %.1f units from the eye" % (fmt(p), np.linalg.norm(p - eye)))
    n = normal[y, x] if normal is not None else None
    reaching = []
    for light in cap.meta["lights"]:
        to = np.array(light["position"]) - p
        d = np.linalg.norm(to)
        if d < light["radius"]:
            ndl = float(np.dot(n, to / d)) if n is not None and np.linalg.norm(n) > 0.5 else float("nan")
            reaching.append((d, light, ndl))
    if not reaching:
        print("  no light reaches it")
    for d, light, ndl in sorted(reaching, key=lambda r: r[0]):
        print("  light %d: %.1f of %.0f units away, colour %s, flags %s, N.L %.2f" % (
            light["index"], d, light["radius"], fmt(light["colour"], 0), light["flags"], ndl))


def surfaces(cap, top=25):
    ids = cap.ids()
    if ids is None:
        print("no id view in this capture")
        return
    light = cap.decoded("light")
    dynamic = cap.decoded("dynamic")
    total = ids.size
    unique, counts = np.unique(ids, return_counts=True)
    order = np.argsort(-counts)
    print("%d surfaces/batches on screen; largest %d:" % (len(unique), min(top, len(unique))))
    for i in order[:top]:
        mask = ids == unique[i]
        line = "  %5.1f%%  " % (100.0 * counts[i] / total)
        if light is not None:
            line += "light %.3f  " % (light[mask] @ LUMA).mean()
        if dynamic is not None:
            line += "dynamic %+.3f  " % (dynamic[mask] @ LUMA).mean()
        print(line + cap.describe(unique[i]))


def diff(cap, a, b, top=20):
    ia, ib = cap.image(a), cap.image(b)
    delta = (ib - ia) @ LUMA
    changed = np.abs(delta) > 2.0 / 255
    print("%s -> %s: %.1f%% of pixels change; mean luminance %.4f -> %.4f" % (
        a, b, 100.0 * changed.mean(), (ia @ LUMA).mean(), (ib @ LUMA).mean()))
    ids = cap.ids()
    if ids is None:
        return
    unique, counts = np.unique(ids, return_counts=True)
    rows = []
    for id_, count in zip(unique, counts):
        mask = ids == id_
        rows.append((abs(delta[mask].mean()) * count, delta[mask].mean(), 100.0 * changed[mask].mean(), 100.0 * count / ids.size, id_))
    rows.sort(reverse=True)
    print("largest changes (weighted by coverage):")
    for _, mean, frac, cover, id_ in rows[:top]:
        print("  %+.4f mean, %5.1f%% of it changed, %5.1f%% of screen: %s" % (mean, frac, cover, cap.describe(id_)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder")
    parser.add_argument("name")
    parser.add_argument("--at", nargs=2, type=int, metavar=("X", "Y"))
    parser.add_argument("--surfaces", action="store_true")
    parser.add_argument("--diff", nargs=2, metavar=("A", "B"))
    args = parser.parse_args()

    cap = Capture(args.folder, args.name)
    m = cap.meta
    print("%s: %dx%d, camera %s, %d lights, settings %s" % (
        m["name"], cap.width, cap.height, fmt(m["camera"]["position"]), len(m["lights"]),
        {k: m["settings"][k] for k in ("lighting", "specular", "aa", "debug_light")}))
    for v in m["variants"]:
        g = v["gpu_ms"]
        print("  variant %-12s view %-8s %s  GPU %.3f ms" % (v["label"], v["view"], v["settings"] or "",
            g["sky_world"] + g["objects"] + g["post"] + g["2d"]))

    if args.at:
        report_pixel(cap, *args.at)
    elif args.surfaces:
        surfaces(cap)
    elif args.diff:
        diff(cap, *args.diff)
    else:
        report_pixel(cap, *crosshair(cap))
        surfaces(cap, top=10)


if __name__ == "__main__":
    sys.exit(main())
