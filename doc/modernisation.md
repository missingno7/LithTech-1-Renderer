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
| Static lamps from the world file; models lit by them (`d_Lighting 1`); lamp shadows from models and world models, alpha-tested bars and grates (`d_Shadows 1`) | done, default off, checked in game | RTX 4090 at 1280×720: whole frame 0.31 ms with 8 shadow pairs; 16 pairs ≈ 24–33 shadow draw calls per frame |
| HDR bloom (`d_Bloom 1`), including fullbright texels and overbright dynamic lighting | implemented, default off; tested in SubwayA on both adapters | See the validation notes below |
| Point-light shadows from static world geometry, models and world models (`d_DynamicShadows 1`) | implemented, default off; tested in SubwayA on both adapters | See the validation notes below |

The iGPU presents through the NVIDIA card's display, so its swapchain writes are unusually slow. Its post-pass numbers
overstate the cost on a GPU that drives the display itself.

## Bloom implementation (2026-10)

`d_Bloom 1` selects a scene pass with the **original UNORM colour plus an R16G16B16A16_SFLOAT bloom-source attachment**
and matching world/object pipelines. Both outputs are written in the same raster pass. Lighting/shadow sums and
texture reads are shared; only material arithmetic is evaluated for the original, HDR and baked-only terms. The
existing swapchain path and UNORM FXAA scene pass remain available. Float images are allocated lazily on first use and rebuilt after a
resize. Devices lacking float attachment, blending or linear-sampling support log that bloom is unavailable and
continue with the existing path.

The bloom source retains lighting above 1; the displayed colour keeps the original lighting and colour clamps.
Source RGB is `clamp(baked-only HDR colour, 0, 1) + (HDR colour - baked-only HDR colour) + emissive boost`, bounded
below by zero. This retains overbright additional lighting while preventing the original baked `Saturate` doubling
from making ordinary white walls/floors glow excessively. DTX_FULLBRITE
palette entries 246–255 already survive upload as texture alpha: those marked texels receive a modest 0.75× texel
emissive addition in the float source. The texture-name list is never consulted. The same metadata is used on world
surfaces, world models and model skins. With modern lighting, per-pixel diffuse and specular from muzzle/explosion
lights also remain overbright. The classic model ramp is still CPU-clamped; enable `d_Lighting 1` for overbright
dynamic lighting on models.

Extraction thresholds four full-resolution source texels before their first 2×2 reduction, with a soft knee of one
quarter of the threshold. This preserves small emissive regions without bilinearly averaging them below threshold
first. Five levels run from half to 1/32 resolution with tent-filtered reductions after extraction, followed by four
tent upsample/merge passes. The final shader
adds the RGB bloom to the clamped original gamma-space base; there is no exposure adjustment, colour grading, linear
conversion or tone mapper. Zero bloom intensity with FXAA off reproduces the bloom-off base exactly. FXAA is optional in that final pass. The 2D overlay is drawn afterwards and never enters
extraction. `d_Compare` leaves the left half on the original shading/clamping path and applies post effects only on
the right. Ordinary bright texels near the soft threshold can contribute a small glow; the default strength is low.

| Command | Default | Range / purpose |
|---|---|---|
| `d_Bloom` | 0 | Enable bloom independently of FXAA and modern lighting |
| `d_BloomIntensity` | 0.15 | 0..2; RGB bloom added at composition |
| `d_BloomThreshold` | 1 | 0.1..8, in the game's gamma-space intensity units |

## Geometry shadows for dynamic lights

Enable `d_Lighting 1` and `d_DynamicShadows 1`. The additional-light equation is now
`diffuse/specular contribution of light i × visibility of light i`. Visibility never subtracts from lightmaps,
pre-lit colours, the model light grid or static lamp illumination. `d_Lighting 0` retains the original lighting;
the point-light shadow option is inactive on that path. Existing static lamp subtraction remains controlled by
`d_Shadows` and is independent of point-light visibility.

Each selected point light renders six 90-degree views into **256×256 D16 atlas subtiles**. Dynamic tiles store radial
distance divided by radius, which avoids poor perspective-depth precision at the far side of a large light. Static
lamp tiles retain their existing perspective depth. Near distance is `max(0.25, min(1, radius × 0.002))`; the face far
plane is the effective light radius. Both face orientation and Vulkan 0..1 projection are defined by `CubeFace` in
`source/dynamic_shadows.d`. All selected lights are redrawn with current positions/radii and current posed objects
each frame; disappearing lights do not leave a retained shadow allocation.

The world reuses its existing vertex and index buffers. A per-polygon index range and AABB are cached when the level
loads. Light-sphere/AABB overlap builds the caster list independently of the camera; conservative per-face AABB
tests reduce draw calls. There is no per-frame world-mesh reconstruction. The BSP/world-tree infrastructure already
collects all relevant objects, including ones outside the camera view. Their posed GPU batches are reused for
casting. Opaque models and world models cast; masked world models and transparent static polygons alpha-test their
actual texture alpha. Fullbright alpha is emission metadata, not opacity. Sky portals, invisible/nonexistent/hull
surfaces, translucent models, the duplicate model fullbright/chrome passes and ReallyClose view objects are excluded
from point-light casting. Untextured effects and polygrids do not cast.

Receivers use nine disk taps. Every tap chooses its own dominant-axis face, so the filter crosses cube seams without
reading an adjacent atlas allocation. Normal/slope offset and a small distance offset control contact acne. Each tap
snaps to its shadow texel centre and intersects the receiver plane to compute the comparison depth there; this avoids
grazing-surface bands from comparing one depth to several differently sloped texels. Radial D16 quantisation bias is
one step. CPU matrices are used for rasterization; the receiver's equivalent cardinal-axis projection avoids nine
matrix fetches per fragment. Smooth model normals can still need bias tuning near silhouettes.

Selection rejects light spheres outside the view frustum and non-bright/invalid-radius lights. It ranks positive
intensity times estimated projected sphere influence (`radius / max(distance, radius)`, squared), times
`1 / (1 + distance / radius)`. The proximity term prioritises a flash close to the eye over an incumbent lamp when
both spheres cover the camera. Engine object
identity gives incumbents a 20% hysteresis bonus; equal scores use stable input order. The synthetic debug light has
a stable identity too. This is conservative view-frustum selection, not a full occlusion query: a bright light behind
a wall may still consume budget. Unselected lights retain their original unshadowed contributions.

| Command | Default | Range / purpose |
|---|---|---|
| `d_DynamicShadows` | 0 | Geometry visibility for modern dynamic lights |
| `d_DynamicShadowLights` | 2 | 0..4 selected point lights; 0 performs no point-light shadow passes |
| `d_Shadows` | 0 | Existing static lamp/model shadows, unchanged control |
| `d_ShadowPairs` | 16 | Requested static lamp/caster budget, 1..64 |

Both kinds share the 4096² atlas, depth render pass, comparison sampler, object caster pipeline and scene storage
buffer. Four dynamic faces fit in a 512² static-lamp tile. Dynamic allocation reserves `ceil(selectedLights × 6 / 4)`
tiles at the end; static pairs use the beginning and are capped to the remaining space. Thus 2 point lights leave
61 static pairs, and 4 leave 58; the default static budget of 16 is unaffected. With dynamic shadows off, all 64
static tiles remain available. An empty atlas is cleared once to establish its sampled layout, then shadow passes
are skipped until needed; a shadow diagnostic capture explicitly clears it. Allocation policies differ while
rendering code and GPU resources remain shared.

## Validation and profiling

The implementation was compiled as x86 with LDC in debug and release configurations, and all nine GLSL shaders were
compiled to Vulkan SPIR-V. Runtime tests used an isolated Blood II copy, command files, the `shadow_test` camera
bookmark in `01_SubwayA`, frame captures and GPU timestamps. No installed game files or level assets were modified.
The Vulkan validation layer was unavailable on this machine; absence of logged runtime errors is not a validation
layer result.

`tools/shadow_tests.d` runs independently of the engine and checks all six face orientations, translated eyes,
near/far clipping, cube boundaries, light-radius and per-face bounds, frustum rejection, brightness/ranking,
hysteresis, zero budget and non-overlapping allocation for budgets 1..4. For example:

```powershell
ldc2 -Isource tools/shadow_tests.d source/dynamic_shadows.d '-of=.build/shadow_tests.exe'
.build/shadow_tests.exe
```

`tools/validate_shadows.py` reconstructs receiver positions from a capture's depth and matrices, then traces rays
through triangulated static polygons from `d_DumpLighting`. Its opaque-static oracle requires every actual quantised
PCF ray to be blocked before expecting zero contribution, so filtered silhouette transitions are not mistaken for
leaks. In the tested view, **187 of 187** such samples had zero dynamic contribution; their median residual was 0.
The oracle excludes alpha-tested surfaces, dynamic casters and undumped Gouraud geometry. It is a targeted world
visibility check, not proof for every map. The shadow debug view now encodes the strongest static/point-light shadow
in green and coverage in blue, with static lamp loss in red.

Capture variants accept `bloom`, `bloomintensity`, `bloomthreshold`, `dynamicshadows`, `dynamicshadowlights` and the
existing `shadows` keys. JSON includes selected point-light indices, world caster counts, all six face matrices and
tile rectangles. GPU stages distinguish static shadows (including atlas setup/clear), dynamic shadow rendering,
world/sky, objects, bloom, final post composition and the overlay. `post` in capture JSON retains its previous
combined bloom/composition meaning, with `bloom` also reported separately. Capture rerenders do not inflate the
normal-frame shadow count/draw-call statistics.

```text
d_Lighting 1
d_DynamicShadows 1
d_DebugLight 400
d_ViewSave test
d_View test
d_DumpLighting 1
wait 1000
capture shadows off:view=dynamic,dynamicshadows=0 on:view=dynamic,dynamicshadows=1 shadow:view=shadow id:view=id
capture bloom off:bloom=0 on:bloom=1 aa:bloom=1,aa=1
```

Run `python tools/validate_shadows.py <captures> shadows <world>_lighting.bin` for the CPU check. Use a single synthetic
light (`DynamicLight 0`, then `d_DebugLight 400`) for that oracle; `DynamicLight 1` restores game lights. Set options
and wait before capture when they change collected geometry or the light list. For static lamp captures, set
`d_Shadows` before collection so the flattened fallback is also changed. `d_View 0` restores the player camera.

The initial ceiling captures exposed self-shadow bands; radial depth and texel-centred receiver-plane comparisons
removed them in the reviewed view. `d_Lighting 0` shadow-off/on captures were byte-identical. Bloom was reviewed on
ceiling lamps, and bloom plus FXAA rendered correctly. Budgets 0, 1, 2 and 4 and simultaneous static/dynamic shadows
were exercised. Moving game lights were rendered each frame and their current positions recorded; broader camera
movement, different maps, explosions, thin grates and doorway/corner arrangements still need a playtest sweep.

Separate original/new game runs showed time-dependent image changes, including changes between two captures of the
untouched renderer. A temporary test DLL therefore rendered the original HEAD world/object fragment shaders and the
new shaders against the **same collected frame**. With bloom/dynamic shadows off, the two full-frame PNGs were
byte-identical both without dynamic lights and with the game lights plus a synthetic 400-unit light. The temporary
comparison pipelines and switch were removed from the shipping source.

Representative images and final timing/compatibility results are in `doc/validation/README.md`. Timings are sample
captures at 1280×720 in one view, not broad benchmarks. The AMD iGPU presents through the NVIDIA display; cold
captures, idle GPU clocks and that presentation path affect timings. Shadow receiver shading is materially more
expensive than rendering the small maps on the iGPU. Start with one shadow light on that adapter, especially at
higher resolutions. Both effects stay disabled by default.

At 1280×720 in the final single-light capture, map rendering took 0.099 ms on RTX 4090 / 0.493 ms on the iGPU;
additional world receiver shading took 0.668 / 4.622 ms. Bloom filtering plus composition (FXAA off) took
0.287 / 0.751 ms, with float-source world shading adding 0.113 / 0.673 ms. These per-stage samples exclude object
shading and should not be read as total feature-cost guarantees; the full capture records are linked above.

Further work should target receiver shader cost and draw batching after profiling, then validate masked geometry,
fast flashes, clipping/bias and selection stability throughout the game. Fixed 256px faces can miss very thin
occluders, filtering deliberately softens boundaries, and geometry closer than the light near plane can be clipped.
Static lamp policy and the existing baked lightmap data are preserved; there is no replacement bake or screen-space
shadow approximation.
