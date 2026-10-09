# Builds d_ren (32-bit) with its shaders embedded, and optionally deploys it to a LithTech 1 game directory or packages
# a release zip.
#   .\build.ps1                                   # debug build
#   .\build.ps1 -Release -GameDir D:\Prog\blood2_test
#   .\build.ps1 -Package                          # release build -> dist\d_ren-<version>.zip
param(
	[string]$GameDir,
	[switch]$Release,
	[switch]$Package,
	[string]$Toolchains = "D:\Prog\toolchains"
)
# No $ErrorActionPreference="Stop": PS 5.1 turns native-tool stderr into terminating errors. Exit codes are checked instead.
Set-Location $PSScriptRoot
if ($Package) { $Release = $true }

$ldc = Get-ChildItem $Toolchains -Directory -Filter "ldc2-*" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($ldc) { $env:PATH = "$($ldc.FullName)\bin;$env:PATH" }
$glslang = Join-Path $Toolchains "glslang\bin\glslang.exe"
if (-not (Test-Path $glslang)) { $glslang = (Get-Command glslangValidator, glslang -ErrorAction SilentlyContinue | Select-Object -First 1).Source }

# shaders: compiled to SPIR-V here, embedded into the DLL by the D build (import(), dub.sdl stringImportPaths)
$shaders = @{ "shader.vert" = "vert.spv"; "shader.frag" = "frag.spv"; "overlay.vert" = "overlay_vert.spv"; "overlay.frag" = "overlay_frag.spv"; "object.vert" = "object_vert.spv"; "object.frag" = "object_frag.spv"; "post.frag" = "post_frag.spv"; "shadow.vert" = "shadow_vert.spv" }
foreach ($src in $shaders.Keys) {
	& $glslang -V $src -o $shaders[$src]; if ($LASTEXITCODE) { throw "$src failed" }
}

# version: one place, source/version_info.d
$version = ([regex]::Match((Get-Content source\version_info.d -Raw), 'DRenVersion\s*=\s*"([^"]+)"')).Groups[1].Value
if (-not $version) { throw "no DRenVersion in source/version_info.d" }

# version resource (file properties), when the Windows SDK's rc.exe is around; the build works without it
$rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter rc.exe -ErrorAction SilentlyContinue |
	Where-Object { $_.FullName -match '\\x64\\|\\x86\\' } | Sort-Object FullName | Select-Object -Last 1
$config = "plain"
if ($rc) {
	$numbers = (($version -split '[^0-9]+' | Where-Object { $_ -ne '' }) + @('0', '0', '0', '0'))[0..3] -join ','
	New-Item -ItemType Directory -Force .build | Out-Null
	@"
1 VERSIONINFO
FILEVERSION $numbers
PRODUCTVERSION $numbers
FILEOS 0x4
FILETYPE 0x2
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "FileDescription", "d_ren - Vulkan renderer for LithTech 1"
      VALUE "FileVersion", "$version"
      VALUE "ProductName", "d_ren"
      VALUE "ProductVersion", "$version"
      VALUE "OriginalFilename", "d_ren.ren"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"@ | Set-Content .build\d_ren.rc -Encoding ascii
	& $rc.FullName /nologo /fo d_ren.res .build\d_ren.rc | Out-Null
	if ($LASTEXITCODE) { throw "rc.exe failed" }
	$config = "versioned"
}

$buildType = if ($Release) { "release" } else { "debug" }
dub build --arch=x86_mscoff --compiler=ldc2 --build=$buildType --config=$config
if ($LASTEXITCODE) { throw "dub build failed" }

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
	# symbols for debugging the game with the renderer loaded
	$pdb = Get-ChildItem "$env:LOCALAPPDATA\dub\cache\d_ren" -Recurse -Filter d_ren.pdb -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
	if ($pdb) { Copy-Item $pdb.FullName $GameDir -Force }
	Write-Host "Deployed d_ren $version to $GameDir. Select it in the game's launcher, or set `"RenderDLL`" `"d_ren.ren`" in autoexec.cfg."
}

if ($Package) {
	# the release: the renderer and its install notes, to unzip into the game folder
	$stage = Join-Path $PSScriptRoot ".build\package"
	if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
	New-Item -ItemType Directory -Force $stage | Out-Null
	Copy-Item d_ren.dll (Join-Path $stage "d_ren.ren")
	(Get-Content release_readme.txt -Raw).Replace('{VERSION}', $version) | Set-Content (Join-Path $stage "d_ren_readme.txt") -Encoding ascii
	New-Item -ItemType Directory -Force dist | Out-Null
	$zip = Join-Path $PSScriptRoot "dist\d_ren-$version.zip"
	if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
	Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
	Write-Host "Packaged $zip"
}
