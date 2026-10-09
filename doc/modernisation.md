# Modern rendering: assessment and plan

d_ren reproduces d3d.ren by default. The modern effects described here are optional layers on top of that baseline:
each can be switched off, and with all of them off the image is the d3d.ren reproduction.

## What the renderer has today (2026-10, v0.2)

- **Frame:** a single render pass draws straight into the swapchain (8-bit UNORM, so all lighting math is in gamma
  space, like the original). The 2D layer is composited in the same pass. Depth can't be sampled. The CPU waits for
  the GPU at the end of every frame (`vkQueueWaitIdle`). There was no GPU timing.
- **World:** a static vertex buffer is built per level and drawn with one draw call per polygon. Every vertex already
  carries its polygon's plane normal. Lightmapped polygons get the dynamic lights per pixel (d3d.ren's per-texel
  formula: no N·L, quadratic falloff). Gouraud polygons get them per vertex.
- **Models:** lit entirely on the CPU into a 16-step light ramp. Inputs are the object's ambient light, the static
  light grid, and a fixed light direction above and behind the camera. Dynamic lights are averaged at the model's
  centre into its ambient light. The vertex normals exist on the CPU (int8, posed for the ramp) but aren't sent to the
  GPU.
- **World models:** lightmapped polygons get per-texel lights like the world. Gouraud polygons are lit per vertex on
  the CPU. The vertex format has no normal.
- **Polygrids:** built on the CPU every frame from the height samples. They have no normals, and the environment pass
  uses slope-based UVs. Nothing marks a polygrid as water.
- **Lights:** only *dynamic* light objects exist at run time: muzzle flashes, explosions, and the levels' LightFX
  objects. Static lights are baked into the lightmaps and into the light grid, which stores a colour per cell but no
  direction. At most 40 dynamic lights are sent per frame.

## Effects ranked by value per cost

| Effect | Change needed | Data available | Missing | Value / cost |
|---|---|---|---|---|
| Per-pixel dynamic lights + N·L (world, world models, models) | shaders, model/world-model normals in the object vertex, a shared light list | world normals, model normals (CPU), light list | nothing | **high / low** |
| Specular from dynamic lights | shader only | as above | material info (start with a conservative texel-based mask) | medium / low |
| Offscreen scene target + post pass | new render pass, 2D composited after it | – | – | prerequisite for everything below |
| FXAA/SMAA, bloom, grading, CAS | post pass | fullbright alpha marks emissive texels | an HDR target for overbright | high / low–medium |
| Water: normals, Fresnel, refraction | polygrid normals from the height field, scene colour/depth copy before translucents | heights, env map | water classification (container under the grid) | high / medium |
| SSAO/GTAO applied to the ambient term only | depth prepass (the world is cheap to draw twice), half-res AO, AO sampled in the main pass | depth | – | medium–high / medium |
| Dynamic-light shadows | cube/atlas shadow maps for a few selected lights | light positions, all geometry | – | medium / high |
| Shadows and specular from static lights | read the static lights from the world file | positions, colours, radii, spot directions in the .dat | the bake formula; the world file name at run time | medium–high / medium |

Static (baked) lights don't exist at run time, but the level files still have them. The editor's `Light`, `DirLight`,
`GlobalDirLight` and `ObjectLight` classes are flagged CF_NORUNTIME: the engine reads their objects from the world file
and skips them (LoadObjects, blood2_recon S_Object.cpp), but the objects and their properties are all there.
`tools/world_objects.py` lists them. 04_steamtunnels has 535 `Light` objects (position, LightRadius, LightColor,
OuterColor, BrightScale, ClipLight = shadowed in the bake, LightObjects = lights models), 171 `DirLight` objects
(spotlights: Rotation as Euler angles, FOV, radius), 1 `ObjectLight`, and 7 `Water` volumes (surface height, texture,
alpha, underwater fog). With them, models can be lit from the real lamps' directions, static lights can give specular
and model shadows, and polygrids inside a `Water` volume can be told apart from other polygrids. d_ren finds the loaded world's file
through the in-process server (verified: `Worlds_steamtunnels.dat`).

The bake, fitted with `tools/lighting_fit.py` against the whole steam tunnels lightmap set (`d_DumpLighting`, 381,665
texels, 58,202 within reach of exactly one lamp): **lightmap = ambient + Σ lamps colour × BrightScale × (1 − d/r)** on
surfaces facing the lamp, no N·L term, with geometry occlusion. Scale 0.97, mean error 0.03 (the RGB565 step); the
quadratic and steeper falloffs fit 2–3× worse. The ambient is a constant per level (steam tunnels: RGB 8, 20, 16), the
value of every texel no lamp reaches. About 28% of in-range facing texels read as shadowed. City hub (8,565 polygons,
315 point and 225 spot lights) gives the same: `1 − d/r`, scale 1.03, error 0.038, its own ambient (16, 20, 16). Spot
lights (`DirLight`): forward = (sin yaw · cos pitch, −sin pitch, cos yaw · cos pitch) from the Euler angles (the other
pitch sign puts the lit texels outside the cones; yaw isn't pinned down by these levels' mostly vertical spots), and
the cone factor is (cos θ − cos h) / (1 − cos h) with h half the FOV (scale 0.98, error 0.024, FOVs 30°..180°), times
the same `1 − d/r`.

## Plan

Phase order, adjusted so that each step delivers something visible and unlocks the next:

1. **Lighting foundation** (now)
   - GPU timestamps per pass in `vk_test.txt`, and `d_GPU` to pick the adapter. The AMD iGPU in the dev machine
     stands in for a modest GPU.
   - `d_Lighting 1`: per-pixel dynamic lights with N·L on the world, world models and models, using one shared light
     function. The model ramp becomes a smooth per-pixel term with the same wrap shape. Blinn-Phong specular from
     dynamic lights, kept conservative. `d_Lighting 0` is d3d.ren exactly.
   - `d_Compare 1`: the left half of the view is drawn d3d.ren-style and the right half with the current settings, for
     A/B screenshots.
2. **Post pipeline:** an offscreen scene target, post pass, then the 2D layer. FXAA first, then bloom (from overbright
   dynamic lights and fullbright texels), grading and optional CAS.
3. **Water:** polygrid normals, Fresnel with the existing environment map, refraction from a scene copy taken before
   the translucent groups, and depth absorption, applied only to polygrids classified as water.
4. **AO:** depth prepass, half-res GTAO-style AO, applied to the lightmap/ambient term only.
5. **Shadows:** a few selected dynamic lights with cube shadow maps and PCF; the flattened d3d.ren model shadow stays
   as the fallback.

Lighting stays in gamma space. The lightmaps, textures and light colours were all tuned in it, and moving to linear
lighting would change the look of every level. Revisit this only with the HDR post pipeline.

## Status

| Step | State | Measured cost (GPU timestamps) |
|---|---|---|
| GPU timing, `d_GPU` | done | – |
| `d_Lighting 1` (per-pixel lights, specular) | done, default off until checked in-game | iGPU at 4K: +0.7 ms with no lights, about +1.3 ms per light covering the view |
| Offscreen target + post pass, `d_AntiAliasing 1` (FXAA) | done, default off | RTX 4090 at 4K: 0.1 ms; iGPU at 4K: +5.5 ms per frame including the extra copy |
| Static lamps from the world file; models lit by them (`d_Lighting 1`); lamp shadows from models (`d_Shadows 1`) | done, default off, first in-game check pending | RTX 4090 at 1280×720: whole frame 0.31 ms with 8 shadow pairs |

The iGPU presents through the NVIDIA card's display, so its swapchain writes are unusually slow. Its post-pass numbers
overstate the cost on a GPU that drives the display itself.
