# Rebuilds the Go bridge only when its sources changed since the last build.
# The Android Gradle build (preBuild) and the Windows CMake build call it;
# build_android.ps1 and build_windows.ps1 still work on their own.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_if_changed.ps1 -Target android
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_if_changed.ps1 -Target windows
#
# The SHA-256 of the sources (*.go without tests, go.mod, go.sum and the
# build script) is kept next to the library as <library>.sha256. Without Go
# (or the NDK / a C compiler) an existing library is used with a warning.
# ZEN_SKIP_GO_BRIDGE=1 skips the check entirely.
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('android', 'windows')]
  [string]$Target
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $root '..\..')).Path
. (Join-Path $root 'bridge_tools.ps1')

if ($Target -eq 'android') {
  $library = Join-Path $projectRoot 'android\app\src\main\jniLibs\arm64-v8a\libyggdrasil_bridge.so'
  $buildScript = Join-Path $root 'build_android.ps1'
} else {
  $library = Join-Path $root 'bin\yggdrasil_bridge.dll'
  $buildScript = Join-Path $root 'build_windows.ps1'
}
$stamp = "$library.sha256"
$haveLibrary = Test-Path $library

if ($env:ZEN_SKIP_GO_BRIDGE -eq '1') {
  Write-Host "Go bridge ($Target): skipped (ZEN_SKIP_GO_BRIDGE=1)."
  exit 0
}

function Get-ZenSourceHash {
  $files = @(Get-ChildItem -Path $root -Filter '*.go' -File |
      Where-Object { $_.Name -notlike '*_test.go' } |
      Sort-Object Name)
  $files += @(Get-Item -LiteralPath (Join-Path $root 'go.mod'), (Join-Path $root 'go.sum'), $buildScript)
  $lines = @(foreach ($file in $files) {
      "$($file.Name) $((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash)"
    })
  $text = (($lines + "target=$Target") -join "`n")
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
}

$hash = Get-ZenSourceHash
if ($haveLibrary -and (Test-Path $stamp) -and ("$(Get-Content -LiteralPath $stamp -Raw)".Trim() -eq $hash)) {
  Write-Host "Go bridge ($Target): up to date."
  exit 0
}

# Tools the build script needs. Without them an existing library is kept.
$missing = @()
if (-not (Find-ZenGo)) {
  $missing += 'Go (https://go.dev/dl/)'
}
if ($Target -eq 'android' -and -not (Find-ZenAndroidNdk)) {
  $missing += 'Android NDK'
}
if ($Target -eq 'windows' -and -not (Find-ZenCCompiler)) {
  $missing += 'a C compiler for cgo (gcc, e.g. Strawberry Perl, or CC)'
}
if ($missing.Count -gt 0) {
  $what = $missing -join ', '
  if ($haveLibrary) {
    Write-Warning "Go bridge ($Target): $what not found - using the existing $library. It may be older than the Go sources; install the tools to rebuild it."
    exit 0
  }
  Write-Error "Go bridge ($Target): $what not found and $library does not exist. Install the tools, or put a prebuilt library there."
  exit 1
}

if ($haveLibrary) {
  Write-Host "Go bridge ($Target): sources changed, rebuilding $library"
} else {
  Write-Host "Go bridge ($Target): building $library"
}
& $buildScript
if (-not (Test-Path $library)) {
  Write-Error "Go bridge ($Target): the build did not produce $library"
  exit 1
}
Set-Content -LiteralPath $stamp -Value $hash -Encoding ASCII
Write-Host "Go bridge ($Target): done."
