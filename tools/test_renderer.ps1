# CPU-only regressions. Build shaders with build.ps1 first; this never starts a game or graphics device.
param([string]$Toolchains = 'D:\Prog\toolchains')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$ldc = Get-ChildItem -LiteralPath $Toolchains -Directory -Filter 'ldc2-*' | Sort-Object Name | Select-Object -Last 1
if (-not $ldc) { throw 'LDC toolchain not found' }
$env:PATH = "$($ldc.FullName)\bin;$env:PATH"
New-Item -ItemType Directory -Path .build -Force | Out-Null
function Run-Test([string]$Name, [string[]]$Sources, [string[]]$Options) {
    $arguments = @('-m32', '-Isource', "-of=.build/$Name.exe") + $Options + $Sources
    & (Join-Path $ldc.FullName 'bin\ldc2.exe') @arguments *> ".build/$Name-build.log"
    if ($LASTEXITCODE) { Get-Content ".build/$Name-build.log" -Tail 20; throw "$Name compilation failed" }
    & ".\.build\$Name.exe"
    if ($LASTEXITCODE) { throw "$Name failed" }
}
Run-Test 'renderer_compat_tests' @('tools/renderer_compat_tests.d','source/renderer_compat.d') @()
Run-Test 'shadow_tests' @('tools/shadow_tests.d','source/dynamic_shadows.d') @()
$paths = (& dub describe --arch=x86_mscoff --compiler=ldc2 --config=versioned --data=import-paths) -join ' '
if ($LASTEXITCODE) { throw 'Dependency description failed' }
$imports = @([regex]::Matches($paths, '"-I([^"]+)"') | ForEach-Object { '-I' + $_.Groups[1].Value.TrimEnd('\') })
$sources = @('tools/model_hook_tests.d') + @(Get-ChildItem source -Recurse -File -Filter '*.d' | ForEach-Object { $_.FullName })
Run-Test 'model_hook_tests' $sources (@('-i','-J.','-dllimport=none','-d-version=RendererCpuTests','-d-version=SDL_205','-d-version=VK_USE_PLATFORM_WIN32_KHR','-Luser32.lib','-Lwinmm.lib') + $imports)
