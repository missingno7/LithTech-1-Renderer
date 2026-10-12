# Matched-renderer compatibility corrections (2026-10-12)

Reference: local `blood2_recon` checkout at `ac026877`, its accepted `recon/state/d3d.ren.tsv`,
the released Blood II AppHeaders, and the renderer sources referenced below. No game was launched
or used for testing during this correction pass.

| Correction | Reference | Result |
|---|---|---|
| Mode enumeration ABI | Released `RMode`; exact `d3d_EnumModesCallback`, RVA `0x15d10` | Hardware field is one byte (`DBOOL`); DLL/name/description start at `1/201/301`. Individual offsets and total size are asserted. |
| Render switches | Exact `d3d_RenderScene`, `0x19970`, and `d3d_DrawModel`, `0x12670` | `DrawEnable` suppresses the complete 3D scene, retaining 2D. `DrawModels` suppresses model collection in normal and object-list scenes. |
| Model hook texturing | Released `MHF_USETEXTURE` contract; exact hook setup `0x10630` | The hook flag reaches model drawing, suppresses skin/environment binding, and selects lit untextured geometry that still casts shadows. |
| Model warble | Exact reset/transform functions `0x10cd0/0x10d10`; exact RenderScene phase update `0x19970` | Original 32-entry sine/interpolation tables, phase advancement and per-source-vertex indexing are preserved for the current full-detail model path. |
| Screenshot callback | Exact `d3d_MakeScreenShot`, `0x1f140` | Engine-requested filename receives a bottom-up 24-bit BGR BMP, including HUD/post effects. Rows are padded for arbitrary widths. |

The model backend's texture gate and `r_SetupWarbleTable` (`0x12a60`) are corroborating reconstructed
source, not accepted strict bodies in the inspected ledger. Their confidence is distinct from the
exact-matched hook and transform functions. No reconstruction source or acceptance state was changed.

The native mode offsets are also confirmed directly in the installed binaries: `d3d.ren`
`0x15d36` writes a byte, `0x15d46/0x15d65` select name offsets `0xc9/0x12d`, and Client.exe
`0x452b7` passes mode+1 to LoadLibrary. The four-byte hardware projection in `lt1_port_abi.h`
is inconsistent with those instructions and the released `DBOOL char` definition.

The Vulkan screenshot request is fulfilled during the next SwapBuffers, after submission completes.
It rerenders the retained frame geometry into an owned offscreen image; it does not read a swapchain
image while presentation owns it. No diagnostic capture files or alternate settings are produced.
The encoded BMP uses the current rendered colour instead of the original renderer's RGB565 backbuffer.

## Code-only validation

`build.ps1` compiles all shaders and the x86 renderer. `tools/test_renderer.ps1` builds/runs three CPU-only
suites without a visible window, SDL initialization or a Vulkan device:

- Released ABI offsets and serialized mode strings.
- Warble interpolation, phase advance, 32-entry wrapping and unclamped base scale; BMP header,
  channel order, row orientation/padding, RGBA/BGRA equivalence and invalid inputs.
- Actual model hook/geometry emission: texture resolution is bypassed, hook light and per-draw flags
  survive, shared face corners deform identically, default texturing remains enabled, and actual
  scene collection honors both render switches.
- Existing cube-face, culling, light selection, atlas packing and masked-fence geometry regressions.
- A message-only Win32 window verifies that ordinary focus loss goes directly to the engine,
  while background mode blocks renderer teardown and removing its hook restores the original procedure.
- Museum fence bounds fit a shadow view even when the lamp is inside the enclosing sphere. An invalid
  lamp cannot consume a slot; two valid lamps produce two shadow pairs within the unchanged atlas budget.

## Focus and masked-wall follow-up

Native Client.exe `MainWndProc` (`0x3700`) calls `r_TermRender` (`0x45650`) on focus loss.
That function terminates and unloads the renderer DLL synchronously. Installing a forwarding window
procedure for normal mode leaves renderer code on the stack across that unload. The focus filter
is now installed only for `d_Background 1`, where it always blocks the teardown message; normal mode
uses the engine procedure directly. Changing the option removes or installs the filter.

Static shadow maps for world models now fit the emitted AABB rather than its enclosing sphere.
This accepts nearby lamps beside thin fences and covers all corners, including oblique light positions.
Projection validity is checked before counting either of the two lamp slots. Animated models keep
their sphere fit. These are extensions to the original renderer, not matched native shadow behavior.

Distance fog (`d_FogMode 1`) is now the default; `0` retains the original device-depth behavior.

The GPU screenshot path, appearance of warble, hook-driven untextured shading and menu/game mode
enumeration still need the user's separate playtest. Model LOD, multiplayer tint and CoolFog remain
outside this pass.
