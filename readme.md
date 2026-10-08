# d_ren - A Vulkan Renderer for LithTech 1

![Screenshot](doc/d_ren_current.png)

*Blood II: The Chosen, first level, rendered by d_ren (borderless fullscreen at 3840x2160, widescreen).*

d_ren is a drop-in replacement for LithTech 1's renderer DLLs (`d3d.ren`, `soft.ren`), written in D on top of Vulkan.
It started as a reverse-engineering prototype of the renderer interface. It now renders Blood II well enough to play:
levels load, and the world, characters, weapons, effects and the 2D interface all draw. It runs at 100+ fps at 4K.

Behaviour is ported from, and checked against, the original Blood II `d3d.ren`. The reference is a reconstruction of its
source plus side-by-side captures of the original running under dgVoodoo2. Where d3d.ren has quirks, d_ren reproduces
them by default (see *Fog* below).

## What it renders
- **World:** lightmaps (two-pass, including Blood II's `Saturate 1` doubling), pre-lit Gouraud surfaces, fullbright
  textures, dynamic lights.
- **Models:** animated characters and weapons (keyframe blending, per-vertex animation, hidden nodes), lit by the
  light grid, the camera-relative directional light and dynamic lights, with fullbright skins and the model hook.
- **World models and containers** (doors, lifts, the train): lightmapped like the world when solid, blended when
  translucent.
- **Sprites:** billboards, glow sprites, z-biased and no-Z sprites, rotatable sprites, and decals clipped to their wall
  polygon.
- **Particle systems, polygrids** (water, with the environment-map pass) and **line systems**.
- **Sky:** sky objects seen through a sky camera that moves through the sky box with the player, behind the sky portals.
- **Screen flashes** (the camera's light add), **fog** (see below), and **the 2D layer** (menus, HUD, console, loading
  screens).
- Objects are drawn in the order of d3d.ren's object queues.

## Not done yet
- Model LOD, model environment maps, the multiplayer skin tint pass, CoolFog.
- The sky, polygrids and line systems are implemented but haven't been checked in-game yet.
- There is no visibility culling: the whole level is drawn every frame. It is still fast.

## Using it
1. Copy `d_ren.dll` (renamed to `d_ren.ren`), the `*.spv` shaders and `test_texture.png` into the game folder.
   `build.ps1 -GameDir <folder>` does this for you.
2. Select it: `"RenderDLL" "d_ren.ren"` in `autoexec.cfg`, or `++RenderDll d_ren.ren` on the command line.
3. Pick any resolution the game offers. d_ren runs borderless fullscreen on the primary monitor and renders 3D at the
   monitor's native resolution. The chosen mode only sets the size of the 2D interface, which is scaled up to fit.
   - With the game's `windowed 1` console variable it runs in a window of the mode's size instead.
   - Only modes up to 1000 pixels high are offered: the engine's own 2D code (the loading-screen warp) crashes above
     that, with any renderer.

Requirements:
- A GPU with Vulkan support, and the 32-bit Vulkan loader (`vulkan-1.dll` in `SysWOW64`, installed by the graphics
  driver).
- On current Windows, Blood II can crash at startup inside DirectInput (a heap overflow in its legacy HID path). That is
  unrelated to the renderer; [dinputto8](https://github.com/elishacloud/dinputto8) as `dinput.dll` in the game folder
  fixes it.

### Widescreen
Blood II sends a 4:3 field of view whatever the resolution, which stretches the 3D view on a wide screen. d3d.ren
stretches it the same way. d_ren keeps the vertical FOV and widens the horizontal one to the screen ("Hor+"). If the
game already sends a widescreen FOV (for example with a widescreen patch), nothing changes. The engine stretches 2D
images such as the loading screen before the renderer sees them, so those need game-side 16:9 art.

### Fog
Blood II levels turn fog on with ranges in world units (e.g. 700 to 2000). d3d.ren draws pre-transformed vertices, so
Direct3D compares those ranges with the 0..1 device depth, and in practice nothing gets fogged. d_ren matches that by
default. `d_FogMode 1` fogs by distance instead, as the level settings suggest was intended.

### Game speed
LithTech 1 steps the game simulation once per rendered frame, but never by less than 10 ms of game time
(`MIN_FRAMETIME` in the server, which in single player runs inside `CLIENT.EXE`). Above 100 fps the game therefore runs
fast: physics, AI and cutscenes at 2.4× speed at 240 fps. The original renderers have the same problem; the engine's
own `MaxFPS` setting stops at 200. With `d_GameSpeedFix 1` d_ren lowers that floor to 1 ms in memory (nothing on disk is
changed): the game runs at normal speed at 240 fps, measured from the server's own clock. If the game's code doesn't
match the expected Blood II 2.1 build, d_ren caps the frame rate at 100 fps instead. `vk_test.txt` logs the measured
game speed once a second.

### Console variables
d_ren's options are engine console variables. On first run they're created with their defaults and marked to be
saved, so after the game exits they appear in `autoexec.cfg`, where they can be edited. In the console, `name value`
changes an option for the current session only; `+name value` also saves it.

| Variable | Default | Meaning |
|---|---|---|
| `d_VSync` | 1 | 1: present in sync with the display (FIFO), paced to its refresh rate; 0: unsynchronised (MAILBOX, else IMMEDIATE). |
| `d_MaxFPS` | 0 | Frame cap; 0 = none (with `d_VSync 1`, the display's refresh rate). |
| `d_GameSpeedFix` | 1 | Keeps the game at normal speed above 100 fps (see *Game speed* below). |
| `d_Widescreen` | 1 | Hor+ FOV correction; 0 projects the game's FOV as given, like d3d.ren. |
| `d_FogMode` | 0 | 0: fog like d3d.ren (device depth); 1: fog by eye distance. |
| `d_DebugClear` | 0 | 1 shows holes in the world in cornflower blue instead of black. |
| `d_ModelFlip`, `d_ModelVertexAnim` | 1 | Model diagnostics: the handedness flip and per-vertex animation. |
| `DrawSky`, `DrawSprites`, `DrawParticles`, `DrawPolyGrids`, `DrawLineSystems`, `LightAddPoly` | 1 | Turn object types off. |

The renderer also reads the game's own `FogEnable`, `FogNearZ`/`FogFarZ`, `FogR/G/B`, `SkyFogNearZ`/`SkyFogFarZ` and
`Saturate`, the same way d3d.ren does.

Logs: `vk_test.txt` (Vulkan setup, once-a-second fps and object statistics) and `test.txt` (engine calls, a
once-a-second heartbeat, and any exception thrown inside the renderer). Both are in the game folder.

## Building
LithTech 1 is 32-bit only, so the renderer must be built as 32-bit. A 64-bit build fails one of the static asserts that
check the shared structure layouts.

Needs [LDC](https://github.com/ldc-developers/ldc) with the 32-bit (multilib) libraries, dub, and `glslang` (or the
Vulkan SDK's `glslangValidator`). `build.ps1` finds them under `-Toolchains` (default `D:\Prog\toolchains`) or on the
`PATH`:
```
.\build.ps1                                     # debug build, shaders compiled
.\build.ps1 -Release -GameDir D:\Games\Blood2   # release build, deployed to the game folder
```
By hand: compile the six shaders (`shader`, `object` and `overlay`, `.vert`/`.frag`) to `vert.spv`/`frag.spv`,
`object_vert.spv`/`object_frag.spv` and `overlay_vert.spv`/`overlay_frag.spv`, then run
`dub build --arch=x86_mscoff --compiler=ldc2`. The `.ren` links druntime, Phobos and the C runtime statically, so it
has no runtime DLL dependencies.

## The Interesting Parts
- `source/renderer_interface.d` and `source/object/*.d` hold the renderer ABI. Anyone working with LithTech 1.0 should
  find them easy to translate to other C-like languages.
- `source/lt_objects.d`, `model_draw.d`, `world_model_draw.d` and `effects_draw.d` read the engine's object data and
  turn it into geometry.
- `source/memory.d` is the Vulkan memory allocator.

## Why Vulkan?
The original author knew Vulkan better than DirectX. Also, without hex-editing the original executable, an OpenGL
context can't be created in the window the engine provides.

Uses [ErupteD](https://github.com/ParticlePeter/ErupteD) as the binding.

## Observations
- Surfaces wider or taller than 5000 px can't be created: the engine checks that at Client.exe 0x0040b09a (file offset
  0xA492). Larger resolutions would need a patch there.
- The engine's 2D warp (used by the loading screen) has 1000-row tables. Modes taller than 1000 rows crash on level
  load, with d3d.ren too.
