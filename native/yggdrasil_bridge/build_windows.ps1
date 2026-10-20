# Builds the Go bridge for Windows as a DLL (c-shared, so cgo and a C
# compiler of the MinGW kind are needed).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_windows.ps1 [-Arch x64|arm64]
#
# x64 (default on an x64 computer): bin\yggdrasil_bridge.dll, with gcc
# (Strawberry Perl, MSYS2, or CC).
# arm64 (default on an ARM64 computer): bin\windows-arm64\yggdrasil_bridge.dll,
# with llvm-mingw's aarch64-w64-mingw32-clang (CC, PATH, C:\llvm-mingw or
# %LOCALAPPDATA%\Programs\llvm-mingw); MSVC's clang cannot build cgo code.
# The CMake build (windows/CMakeLists.txt) calls this through
# build_if_changed.ps1 with the architecture Flutter builds for.
param(
  [ValidateSet('', 'x64', 'arm64')]
  [string]$Arch = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'bridge_tools.ps1')

if (-not $Arch) {
  $Arch = Get-ZenWindowsHostArch
}

$go = Find-ZenGo
if (-not $go) {
  throw "Go not found: neither portable Go in $env:LOCALAPPDATA\Programs\GoPortable nor go on PATH"
}
$env:PATH = "$(Split-Path $go.Exe -Parent);$env:PATH"
if ($go.Root) {
  $env:GOROOT = $go.Root
}

$cc = Find-ZenCCompiler -Arch $Arch
if (-not $cc) {
  if ($Arch -eq 'arm64') {
    throw 'No C compiler for windows/arm64: install llvm-mingw (https://github.com/mstorsjo/llvm-mingw) or set CC to aarch64-w64-mingw32-clang'
  }
  throw 'No C compiler for cgo: install gcc (e.g. Strawberry Perl) or set CC'
}
$env:CC = $cc
$env:CGO_ENABLED = '1'
$env:GOOS = 'windows'
$env:GOARCH = if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64' }

$output = Get-ZenWindowsBridgePath -Root $root -Arch $Arch
New-Item -ItemType Directory -Path (Split-Path $output -Parent) -Force | Out-Null
Write-Host "Go bridge: building windows/$Arch with $cc"
Push-Location $root
try {
  & $go.Exe build -trimpath -buildmode=c-shared -ldflags="-s -w" -o $output .
  if ($LASTEXITCODE -ne 0) {
    throw "go build failed (windows/$Arch)"
  }
}
finally {
  Pop-Location
}
