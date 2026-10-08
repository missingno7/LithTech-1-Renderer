d_ren {VERSION} - Vulkan renderer for LithTech 1 (Blood II: The Chosen)
=====================================================================

A replacement for the game's d3d.ren / soft.ren, written against Vulkan. It renders Blood II at high resolutions and
high frame rates, with widescreen, smooth 240 fps mouse look and correct game speed above 100 fps.

Source and issues: https://github.com/missingno7/LithTech-1-Renderer


INSTALL
-------
1. Unzip d_ren.ren into the Blood II folder (next to CLIENT.EXE).
2. Start the game's launcher, open the display settings and pick the d_ren renderer and a resolution.
   (Or set  "RenderDLL" "d_ren.ren"  in autoexec.cfg.)

The 3D view always renders at your monitor's full resolution, borderless fullscreen on the primary monitor. The
resolution you pick only sets the size of the menus and HUD: a lower 16:9 mode gives a bigger HUD (1280x720 on a 4K
screen = 3x). Modes taller than 1000 pixels aren't offered: the game itself crashes above that.

To uninstall, pick another renderer in the launcher and delete d_ren.ren.


REQUIREMENTS
------------
- A graphics card and driver with Vulkan support (any card from the last ten years or so).
- Blood II 2.1. Other versions should work, but the game-speed fix is made for 2.1; on other versions frames are
  capped at 100 fps so the game doesn't run fast.

Recommended, separate projects:
- dinputto8 (https://github.com/elishacloud/dinputto8): put its dinput.dll in the game folder if Blood II crashes at
  startup on current Windows (a DirectInput problem unrelated to the renderer).
- A Blood II widescreen patch, for 16:9 menus and loading screens.


OPTIONS
-------
Console variables. They are written to autoexec.cfg after the first run and can be edited there. In the console,
"name value" changes one for this session; "+name value" also saves it.

  d_VSync 1         1: in sync with the display, at its refresh rate. 0: unlimited (may tear).
  d_MaxFPS 0        Frame rate cap, 0 = none.
  d_GameSpeedFix 1  Normal game speed above 100 fps (the engine runs the game too fast there).
  d_MouseFix 1      Smooth mouse look above ~64 fps.
  d_Widescreen 1    Widescreen field of view. 0: the original stretched view.
  d_FogMode 0       0: fog as the original renderer shows it. 1: fog by distance.
  d_DebugClear 0    1: show holes in the level in blue.


KNOWN LIMITATIONS
-----------------
- Not yet done: chrome (environment-mapped) models, dynamic lights on lightmapped walls are softer than the original,
  moving cloud shadows outdoors, model detail levels, the game's screenshot key.
- The sky, water and some effects (line systems) are implemented but haven't been checked against the original in
  every level yet.


REPORTING PROBLEMS
------------------
The renderer writes vk_test.txt and test.txt into the game folder. They're rewritten at every start and are useful to
attach to a bug report, together with what you were doing and, if possible, a screenshot.
