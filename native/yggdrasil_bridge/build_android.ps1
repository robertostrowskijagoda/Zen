$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $root '..\..')
. (Join-Path $root 'bridge_tools.ps1')

# Portable Go first (as before), else go on PATH.
$go = Find-ZenGo
if (-not $go) {
  throw "Go not found: neither portable Go in $env:LOCALAPPDATA\Programs\GoPortable nor go on PATH"
}

# ANDROID_NDK_HOME, ANDROID_HOME / ANDROID_SDK_ROOT, or the default SDK folder.
$ndkRoot = Find-ZenAndroidNdk
if (-not $ndkRoot) {
  throw "Android NDK not found (set ANDROID_NDK_HOME or install it in the Android SDK)"
}

$toolchainBin = Join-Path $ndkRoot.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin'
if (-not (Test-Path $toolchainBin)) {
  throw "Android NDK LLVM toolchain not found at $toolchainBin"
}

$abis = @(
  @{ Abi = 'arm64-v8a'; GoArch = 'arm64'; Clang = 'aarch64-linux-android21-clang.cmd' }
)

$env:PATH = "$(Split-Path $go.Exe -Parent);$env:PATH"
if ($go.Root) {
  $env:GOROOT = $go.Root
}
$env:GOOS = 'android'
$env:CGO_ENABLED = '1'

Push-Location $root
try {
  foreach ($abi in $abis) {
    $outDir = Join-Path $projectRoot "android\app\src\main\jniLibs\$($abi.Abi)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $env:GOARCH = $abi.GoArch
    if ($abi.ContainsKey('GoArm')) {
      $env:GOARM = $abi.GoArm
    } else {
      Remove-Item Env:GOARM -ErrorAction SilentlyContinue
    }

    $env:CC = Join-Path $toolchainBin $abi.Clang
    if (-not (Test-Path $env:CC)) {
      throw "Android clang compiler not found at $($env:CC)"
    }

    $output = Join-Path $outDir 'libyggdrasil_bridge.so'
    & $go.Exe build -trimpath -buildmode=c-shared -ldflags='-s -w -checklinkname=0' -o $output .
    if ($LASTEXITCODE -ne 0) {
      throw "go build failed for $($abi.Abi)"
    }

    $strip = Join-Path $toolchainBin 'llvm-strip.exe'
    if (Test-Path $strip) {
      & $strip --strip-unneeded $output
    }

    $header = Join-Path $outDir 'libyggdrasil_bridge.h'
    if (Test-Path $header) {
      Remove-Item $header -Force
    }
  }
}
finally {
  Pop-Location
}
