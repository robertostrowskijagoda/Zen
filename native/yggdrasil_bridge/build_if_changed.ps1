# Rebuilds the Go bridge only when its sources changed since the last build.
# The Android Gradle build (preBuild) and the Windows CMake build call it;
# build_android.ps1 and build_windows.ps1 still work on their own.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_if_changed.ps1 -Target android [-Abis arm64-v8a,x86_64]
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_if_changed.ps1 -Target windows [-Arch x64|arm64]
#
# The SHA-256 of the sources (*.go without tests, go.mod, go.sum and the
# build script, plus the ABI or architecture and `go version`, so a Go
# release with security fixes rebuilds too) is kept next to each library as
# <library>.sha256, so every Android ABI and Windows architecture is checked
# and rebuilt on its own. Android ABIs: -Abis, else ZEN_ANDROID_ABIS (set by
# Gradle from the ABIs it packages), else all. Without Go (or the NDK / a C
# compiler) an existing library is used with a warning.
# ZEN_SKIP_GO_BRIDGE=1 skips the check entirely.
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('android', 'windows')]
  [string]$Target,
  [string]$Abis = '',
  [ValidateSet('', 'x64', 'arm64')]
  [string]$Arch = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $root '..\..')).Path
. (Join-Path $root 'bridge_tools.ps1')

if ($env:ZEN_SKIP_GO_BRIDGE -eq '1') {
  Write-Host "Go bridge ($Target): skipped (ZEN_SKIP_GO_BRIDGE=1)."
  exit 0
}

# One entry per library: its name in messages, path and hash salt.
$libraries = @()
if ($Target -eq 'android') {
  $buildScript = Join-Path $root 'build_android.ps1'
  if (-not $Abis) {
    $Abis = $env:ZEN_ANDROID_ABIS
  }
  foreach ($abi in @(Select-ZenAndroidAbis -List $Abis)) {
    $libraries += @{
      Name = "android/$($abi.Abi)"
      Key = $abi.Abi
      Path = Join-Path $projectRoot "android\app\src\main\jniLibs\$($abi.Abi)\libyggdrasil_bridge.so"
      Salt = "target=android abi=$($abi.Abi)"
    }
  }
} else {
  $buildScript = Join-Path $root 'build_windows.ps1'
  if (-not $Arch) {
    $Arch = Get-ZenWindowsHostArch
  }
  $libraries += @{
    Name = "windows/$Arch"
    Key = $Arch
    Path = Get-ZenWindowsBridgePath -Root $root -Arch $Arch
    # x64 keeps the salt of the single-architecture days, so an existing
    # stamp stays valid.
    Salt = if ($Arch -eq 'x64') { 'target=windows' } else { "target=windows arch=$Arch" }
  }
}

# The Go that would build the library (go.mod may pick another toolchain,
# so asked from the module folder); empty without Go.
$goVersion = ''
$goTool = Find-ZenGo
if ($goTool) {
  Push-Location $root
  try {
    $goVersion = "$(& $goTool.Exe version 2>$null)".Trim()
  } catch {
    $goVersion = ''
  } finally {
    Pop-Location
  }
}

function Get-ZenSourceHash([string]$Salt) {
  $files = @(Get-ChildItem -Path $root -Filter '*.go' -File |
      Where-Object { $_.Name -notlike '*_test.go' } |
      Sort-Object Name)
  # The bridge's own packages (internal/mldsa, internal/zensig).
  $files += @(Get-ChildItem -Path (Join-Path $root 'internal') -Filter '*.go' -File -Recurse |
      Where-Object { $_.Name -notlike '*_test.go' } |
      Sort-Object FullName)
  $files += @(Get-Item -LiteralPath (Join-Path $root 'go.mod'), (Join-Path $root 'go.sum'), $buildScript)
  $lines = @(foreach ($file in $files) {
      "$($file.Name) $((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash)"
    })
  $text = (($lines + $Salt + "go=$goVersion") -join "`n")
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
}

$stale = @()
foreach ($library in $libraries) {
  $library.Hash = Get-ZenSourceHash $library.Salt
  $library.Stamp = "$($library.Path).sha256"
  $library.Exists = Test-Path $library.Path
  if ($library.Exists -and (Test-Path $library.Stamp) -and
    ("$(Get-Content -LiteralPath $library.Stamp -Raw)".Trim() -eq $library.Hash)) {
    Write-Host "Go bridge ($($library.Name)): up to date."
  } else {
    $stale += $library
  }
}
if ($stale.Count -eq 0) {
  exit 0
}

# Tools the build script needs. Without them existing libraries are kept.
$missing = @()
if (-not (Find-ZenGo)) {
  $missing += 'Go (https://go.dev/dl/)'
}
if ($Target -eq 'android' -and -not (Find-ZenAndroidNdk)) {
  $missing += 'Android NDK'
}
if ($Target -eq 'windows' -and -not (Find-ZenCCompiler -Arch $Arch)) {
  if ($Arch -eq 'arm64') {
    $missing += 'a C compiler for cgo on ARM64 (llvm-mingw, or CC)'
  } else {
    $missing += 'a C compiler for cgo (gcc, e.g. Strawberry Perl, or CC)'
  }
}
if ($missing.Count -gt 0) {
  $what = $missing -join ', '
  $absent = @($stale | Where-Object { -not $_.Exists })
  if ($absent.Count -eq 0) {
    foreach ($library in $stale) {
      Write-Warning "Go bridge ($($library.Name)): $what not found - using the existing $($library.Path). It may be older than the Go sources; install the tools to rebuild it."
    }
    exit 0
  }
  Write-Error "Go bridge ($Target): $what not found and $(($absent | ForEach-Object { $_.Path }) -join ', ') does not exist. Install the tools, or put a prebuilt library there."
  exit 1
}

foreach ($library in $stale) {
  if ($library.Exists) {
    Write-Host "Go bridge ($($library.Name)): sources changed, rebuilding $($library.Path)"
  } else {
    Write-Host "Go bridge ($($library.Name)): building $($library.Path)"
  }
}
if ($Target -eq 'android') {
  & $buildScript -Abis (($stale | ForEach-Object { $_.Key }) -join ',')
} else {
  & $buildScript -Arch $Arch
}
foreach ($library in $stale) {
  if (-not (Test-Path $library.Path)) {
    Write-Error "Go bridge ($($library.Name)): the build did not produce $($library.Path)"
    exit 1
  }
  Set-Content -LiteralPath $library.Stamp -Value $library.Hash -Encoding ASCII
}
Write-Host "Go bridge ($Target): done."
