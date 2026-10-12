"""Check a captured dynamic-light visibility view against rays through dumped static polygons.

Usage: python tools/validate_shadows.py <captures> <name> <world>_lighting.bin
Requires capture variants off/on (view=dynamic) and id (view=id), one debug light,
and d_DumpLighting. This checks opaque lightmapped world polygons; dynamic casters,
masked surfaces, edge-filter transitions and undumped Gouraud blockers are outside the CPU oracle.
"""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image
from lighting_fit import read_dump


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('name')
    parser.add_argument('dump', type=Path)
    args = parser.parse_args()
    root, name = args.captures, args.name
    meta = json.loads((root / f'{name}.json').read_text())
    assert len(meta['lights']) == 1, 'use DynamicLight 0 and d_DebugLight <radius>'
    eye = np.array(meta['lights'][0]['position'])
    radius = meta['lights'][0]['radius']
    images = {key: np.asarray(Image.open(root / f'{name}_{key}.png')).astype(float)
              for key in ['off', 'on', 'id']}
    ids = images['id'].astype(np.uint32)
    ids = ids[:, :, 0] + ids[:, :, 1] * 256 + ids[:, :, 2] * 65536
    depth = np.fromfile(root / meta['depth']['file'], '<f4').reshape(meta['height'], meta['width'])
    matrices = meta['matrices']
    inv = np.linalg.inv(np.array(matrices['proj']).reshape(4, 4).T @
                        np.array(matrices['view']).reshape(4, 4).T)
    vx, vy, vw, vh = meta['viewport']
    polygons = read_dump(args.dump)
    by_id = {p['index'] + 1: p for p in polygons}
    triangles, owners = [], []
    for p in polygons:
        if p['flags'] & (2 | 4 | 8 | 16 | 0x400):
            continue
        for j in range(1, len(p['verts']) - 1):
            triangles.append(p['verts'][[0, j, j + 1]])
            owners.append(p['index'] + 1)
    triangles = np.array(triangles)
    owners = np.array(owners)
    a, e1, e2 = triangles[:, 0], triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0]
    tvec = eye - a
    qvec = np.cross(tvec, e1)
    checked = centre_blocked = blocked = suppressed = lit = lit_preserved = 0
    residuals = []
    failures = []
    axes = np.array([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], float)
    taps = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (.7, .7), (-.7, .7), (.7, -.7), (-.7, -.7)]

    def occluded(ray, owner):
        h = np.cross(ray, e2)
        det = np.einsum('ij,ij->i', e1, h)
        with np.errstate(divide='ignore', invalid='ignore'):
            u = np.einsum('ij,ij->i', tvec, h) / det
            v = qvec @ ray / det
            t = np.einsum('ij,ij->i', e2, qvec) / det
            return bool(((np.abs(det) > 1e-7) & (u >= 0) & (v >= 0) & (u + v <= 1) &
                         (t > 0) & (t * np.linalg.norm(ray) < np.linalg.norm(ray) - 2) & (owners != owner)).any())

    def all_pcf_rays_blocked(p, normal, owner):
        axis = (p - eye) / np.linalg.norm(p - eye)
        tangent = np.cross([1, 0, 0] if abs(axis[1]) > .95 else [0, 1, 0], axis)
        tangent /= np.linalg.norm(tangent)
        bitangent = np.cross(axis, tangent)
        nl = max(normal @ -axis, 0)
        bias = max(.08, min(.6, radius / 1024)) * (1 - nl)
        receiver = p + normal * bias - axis * .04
        for tx, ty in taps:
            q = receiver + (tangent * tx + bitangent * ty) * np.linalg.norm(p - eye) * 2 / 256
            component = int(np.argmax(np.abs(q - eye)))
            face = component * 2 + int(q[component] < eye[component])
            forward = axes[face]
            right = np.cross([0, 0, 1] if component == 1 else [0, 1, 0], forward)
            up = np.cross(forward, right)
            ray = q - eye
            ndc = np.array([right @ ray, up @ ray]) / (forward @ ray)
            pixel = np.clip(np.floor((ndc * .5 + .5) * 256), 0, 255)
            snapped = (pixel + .5) * 2 / 256 - 1
            direction = forward + right * snapped[0] + up * snapped[1]
            denominator = normal @ direction
            if abs(denominator) < .0001:
                return False
            ray = direction * (normal @ (receiver - eye)) / denominator
            if not occluded(ray, owner):
                return False
        return True
    for y in range(8, meta['height'] - 8, 8):
        for x in range(8, meta['width'] - 8, 8):
            owner = int(ids[y, x])
            if owner not in by_id:
                continue
            p = inv @ [2 * (x + .5 - vx) / vw - 1, 2 * (y + .5 - vy) / vh - 1, depth[y, x], 1]
            p = p[:3] / p[3]
            ray = p - eye
            distance = np.linalg.norm(ray)
            normal = by_id[owner]['normal']
            if distance >= radius or normal @ -ray <= .05 * distance:
                continue
            off = np.linalg.norm(images['off'][y, x] - 128)
            on = np.linalg.norm(images['on'][y, x] - 128)
            if off < 8:
                continue
            h = np.cross(ray, e2)
            det = np.einsum('ij,ij->i', e1, h)
            with np.errstate(divide='ignore', invalid='ignore'):
                u = np.einsum('ij,ij->i', tvec, h) / det
                v = qvec @ ray / det
                t = np.einsum('ij,ij->i', e2, qvec) / det
            hits = ((np.abs(det) > 1e-7) & (u >= 0) & (v >= 0) & (u + v <= 1) &
                    (t > 0) & (t * distance < distance - 2) & (owners != owner))
            solid_hits = hits & (u > .02) & (v > .02) & (u + v < .98)
            checked += 1
            if solid_hits.any():
                centre_blocked += 1
                # A hard centre ray at a shadow edge is expected to disagree with filtered visibility.
                # Require opaque static blockers along every actual quantised PCF ray for the zero-light check.
                if not all_pcf_rays_blocked(p, normal, owner):
                    continue
                blocked += 1
                residuals.append(on / off)
                suppressed += int(on <= 2)
                if on > 2:
                    failures.append(dict(x=x, y=y, polygon=owner, residual=float(on / off)))
            elif not hits.any():
                lit += 1
                lit_preserved += int(abs(on - off) <= 2)
    report = dict(samples=checked, centre_ray_blocked=centre_blocked, all_pcf_rays_static_blocked=blocked, fully_suppressed=suppressed,
                  blocked_median_residual=float(np.median(residuals)) if residuals else None,
                  no_dumped_blocker=lit, unblocked_preserved=lit_preserved, failures=failures)
    print(json.dumps(report, indent=2))
    (root / f'{name}_raycheck.json').write_text(json.dumps(report, indent=2) + '\n')
    assert blocked > 0, 'this view has no confident static occlusion samples'
    assert suppressed / blocked > .9, 'inspect leakage or PCF edge cases before accepting the result'


if __name__ == '__main__':
    main()
