# Matched-renderer compatibility corrections (2026-10-12)

Reference: local `blood2_recon` checkout at `ac026877`, its accepted `recon/state/d3d.ren.tsv`,
the released Blood II AppHeaders, and the renderer sources referenced below. No game was launched
or used for testing during this correction pass.

| Correction | Reference | Result |
|---|---|---|
| Mode enumeration ABI | Released `RMode`; exact `d3d_EnumModesCallback`, RVA `0x15d10` | Hardware field is four bytes; DLL/name/description start at `4/204/304`. Individual offsets and total size are asserted. |
| Render switches | Exact `d3d_RenderScene`, `0x19970`, and `d3d_DrawModel`, `0x12670` | `DrawEnable` suppresses the complete 3D scene, retaining 2D. `DrawModels` suppresses model collection in normal and object-list scenes. |
| Model hook texturing | Released `MHF_USETEXTURE` contract; exact hook setup `0x10630` | The hook flag reaches model drawing, suppresses skin/environment binding, and selects lit untextured geometry that still casts shadows. |
| Model warble | Exact reset/transform functions `0x10cd0/0x10d10`; exact RenderScene phase update `0x19970` | Original 32-entry sine/interpolation tables, phase advancement and per-source-vertex indexing are preserved for the current full-detail model path. |
| Screenshot callback | Exact `d3d_MakeScreenShot`, `0x1f140` | Engine-requested filename receives a bottom-up 24-bit BGR BMP, including HUD/post effects. Rows are padded for arbitrary widths. |

The model backend's texture gate and `r_SetupWarbleTable` (`0x12a60`) are corroborating reconstructed
source, not accepted strict bodies in the inspected ledger. Their confidence is distinct from the
exact-matched hook and transform functions. No reconstruction source or acceptance state was changed.

The Vulkan screenshot request is fulfilled during the next SwapBuffers, after submission completes.
It rerenders the retained frame geometry into an owned offscreen image; it does not read a swapchain
image while presentation owns it. No diagnostic capture files or alternate settings are produced.
The encoded BMP uses the current rendered colour instead of the original renderer's RGB565 backbuffer.

## Code-only validation

`build.ps1` compiles all shaders and the x86 renderer. `tools/test_renderer.ps1` builds/runs three CPU-only
suites without a window, SDL initialization or a Vulkan device:

- Released ABI offsets and serialized mode strings.
- Warble interpolation, phase advance, 32-entry wrapping and unclamped base scale; BMP header,
  channel order, row orientation/padding, RGBA/BGRA equivalence and invalid inputs.
- Actual model hook/geometry emission: texture resolution is bypassed, hook light and per-draw flags
  survive, shared face corners deform identically, default texturing remains enabled, and actual
  scene collection honors both render switches.
- Existing cube-face, culling, light selection, atlas packing and masked-fence geometry regressions.

The GPU screenshot path, appearance of warble, hook-driven untextured shading and menu/game mode
enumeration still need the user's separate playtest. Model LOD, multiplayer tint and CoolFog remain
outside this pass.
