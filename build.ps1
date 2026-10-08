# Builds d_ren (32-bit), compiles shaders, and optionally deploys to a LithTech 1 game directory.
#   .\build.ps1                                   # debug build
#   .\build.ps1 -Release -GameDir D:\Prog\blood2_test
param(
	[string]$GameDir,
	[switch]$Release,
	[string]$Toolchains = "D:\Prog\toolchains"
)
# No $ErrorActionPreference="Stop": PS 5.1 turns native-tool stderr into terminating errors. Exit codes are checked instead.
Set-Location $PSScriptRoot

$ldc = Get-ChildItem $Toolchains -Directory -Filter "ldc2-*" | Sort-Object Name | Select-Object -Last 1
if ($ldc) { $env:PATH = "$($ldc.FullName)\bin;$env:PATH" }
$glslang = Join-Path $Toolchains "glslang\bin\glslang.exe"
if (-not (Test-Path $glslang)) { $glslang = (Get-Command glslangValidator, glslang -ErrorAction SilentlyContinue | Select-Object -First 1).Source }

$shaders = @{ "shader.vert" = "vert.spv"; "shader.frag" = "frag.spv"; "overlay.vert" = "overlay_vert.spv"; "overlay.frag" = "overlay_frag.spv"; "object.vert" = "object_vert.spv"; "object.frag" = "object_frag.spv" }
foreach ($src in $shaders.Keys) {
	& $glslang -V $src -o $shaders[$src]; if ($LASTEXITCODE) { throw "$src failed" }
}

$buildType = if ($Release) { "release" } else { "debug" }
dub build --arch=x86_mscoff --compiler=ldc2 --build=$buildType
if ($LASTEXITCODE) { throw "dub build failed" }

# Dummy texture the renderer loads during menus; must be 8-bit RGBA.
if (-not (Test-Path test_texture.png)) {
	Add-Type -AssemblyName System.Drawing
	$bmp = New-Object System.Drawing.Bitmap 16, 16, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	for ($y = 0; $y -lt 16; $y++) { for ($x = 0; $x -lt 16; $x++) {
		$c = if ((($x -shr 2) + ($y -shr 2)) % 2) { [System.Drawing.Color]::Magenta } else { [System.Drawing.Color]::Black }
		$bmp.SetPixel($x, $y, $c)
	} }
	$bmp.Save((Join-Path $PSScriptRoot "test_texture.png"), [System.Drawing.Imaging.ImageFormat]::Png)
	$bmp.Dispose()
}

if ($GameDir) {
	# a renderer still loaded by a running (or hung) game can't be overwritten, but it can be renamed out of the way
	$target = Join-Path $GameDir "d_ren.ren"
	if (Test-Path $target) {
		try { [IO.File]::Copy((Join-Path $PSScriptRoot "d_ren.dll"), $target, $true) }
		catch {
			$stale = "$target.old-$(Get-Date -Format yyyyMMddHHmmss)"
			Rename-Item $target $stale -ErrorAction Stop
			Write-Host "d_ren.ren was in use, moved it to $stale"
			[IO.File]::Copy((Join-Path $PSScriptRoot "d_ren.dll"), $target, $true)
		}
	} else {
		[IO.File]::Copy((Join-Path $PSScriptRoot "d_ren.dll"), $target, $true)
	}
	if ((Get-Item $target).Length -ne (Get-Item d_ren.dll).Length) { throw "d_ren.ren was not updated" }
	Copy-Item @($shaders.Values) $GameDir -Force -ErrorAction Stop
	Copy-Item test_texture.png $GameDir -Force
	# symbols for debugging the game with the renderer loaded
	$pdb = Get-ChildItem "$env:LOCALAPPDATA\dub\cache\d_ren" -Recurse -Filter d_ren.pdb -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
	if ($pdb) { Copy-Item $pdb.FullName $GameDir -Force }
	Write-Host "Deployed to $GameDir. Set `"RenderDLL`" `"d_ren.ren`" in its autoexec.cfg to use it."
}
