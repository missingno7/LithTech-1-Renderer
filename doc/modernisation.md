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
| Shadows from static lights | – | – | static light positions (not in the runtime data) | not feasible without extra data |

Not feasible without new data: specular or shadows from the static (baked) lights. The light grid stores no direction,
and the static lights themselves don't exist at run time. Directional lightmaps or light-position extraction from the
level files could add that later.

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
