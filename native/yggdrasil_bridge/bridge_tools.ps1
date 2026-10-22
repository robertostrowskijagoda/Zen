# Shared lookups for the Go bridge build scripts (dot-sourced).
# ASCII only: Windows PowerShell 5.1 reads scripts without a BOM as ANSI.

# Go: the portable install the project uses, else go on PATH. $null if none.
function Find-ZenGo {
  $portableRoot = Join-Path $env:LOCALAPPDATA 'Programs\GoPortable\Go'
  $portable = Join-Path $portableRoot 'bin\go.exe'
  if (Test-Path $portable) {
    return @{ Exe = $portable; Root = $portableRoot }
  }
  $onPath = Get-Command go -ErrorAction SilentlyContinue
  if ($onPath) {
    return @{ Exe = $onPath.Source; Root = $null }
  }
  return $null
}

# Newest Android NDK: ANDROID_NDK_HOME, else <sdk>\ndk\<newest> of
# ANDROID_HOME, ANDROID_SDK_ROOT or the default SDK folder. $null if none.
function Find-ZenAndroidNdk {
  if ($env:ANDROID_NDK_HOME -and (Test-Path $env:ANDROID_NDK_HOME)) {
    return Get-Item $env:ANDROID_NDK_HOME
  }
  $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\sdk')) |
    Where-Object { $_ }
  foreach ($sdkRoot in $sdkRoots) {
    $ndkDir = Join-Path $sdkRoot 'ndk'
    if (Test-Path $ndkDir) {
      # By version, not by name ("9.x" would sort above "28.x").
      $ndk = Get-ChildItem $ndkDir -Directory |
        Sort-Object { $v = $null; if ([version]::TryParse($_.Name, [ref]$v)) { $v } else { [version]'0.0' } } -Descending |
        Select-Object -First 1
      if ($ndk) {
        return $ndk
      }
    }
  }
  return $null
}

# C compiler for cgo on Windows: CC, else for x64 gcc on PATH or Strawberry
# Perl's gcc, for arm64 llvm-mingw's aarch64-w64-mingw32-clang (PATH,
# C:\llvm-mingw or %LOCALAPPDATA%\Programs\llvm-mingw). $null if none.
function Find-ZenCCompiler {
  param([string]$Arch = 'x64')
  if ($env:CC) {
    return $env:CC
  }
  if ($Arch -eq 'arm64') {
    $onPath = Get-Command aarch64-w64-mingw32-clang -ErrorAction SilentlyContinue
    if ($onPath) {
      return $onPath.Source
    }
    foreach ($dir in @('C:\llvm-mingw', (Join-Path $env:LOCALAPPDATA 'Programs\llvm-mingw'))) {
      $clang = Join-Path $dir 'bin\aarch64-w64-mingw32-clang.exe'
      if (Test-Path $clang) {
        return $clang
      }
    }
    return $null
  }
  $onPath = Get-Command gcc -ErrorAction SilentlyContinue
  if ($onPath) {
    return $onPath.Source
  }
  $strawberry = 'C:\Strawberry\c\bin\gcc.exe'
  if (Test-Path $strawberry) {
    return $strawberry
  }
  return $null
}

# This computer's Windows architecture ('x64' or 'arm64'), also from an x64
# PowerShell running emulated on ARM64.
function Get-ZenWindowsHostArch {
  try {
    $os = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ("$os" -eq 'Arm64') {
      return 'arm64'
    }
    if ("$os" -eq 'X64') {
      return 'x64'
    }
  } catch {
    # Older .NET: the environment below.
  }
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    return 'arm64'
  }
  return 'x64'
}

# Where build_windows.ps1 puts the DLL: bin\yggdrasil_bridge.dll for x64 (as
# always), bin\windows-arm64\yggdrasil_bridge.dll for arm64. Dart's debug
# lookup (yggdrasil_bridge_ffi.dart) uses the same paths.
function Get-ZenWindowsBridgePath {
  param([string]$Root, [string]$Arch = 'x64')
  if ($Arch -eq 'arm64') {
    return (Join-Path $Root 'bin\windows-arm64\yggdrasil_bridge.dll')
  }
  return (Join-Path $Root 'bin\yggdrasil_bridge.dll')
}

# Android ABIs the Go bridge is built for (the same as abiFilters in
# android/app/build.gradle.kts): Go architecture and NDK clang of each.
function Get-ZenAndroidAbis {
  return @(
    @{ Abi = 'arm64-v8a'; GoArch = 'arm64'; Clang = 'aarch64-linux-android21-clang.cmd' },
    @{ Abi = 'armeabi-v7a'; GoArch = 'arm'; GoArm = '7'; Clang = 'armv7a-linux-androideabi21-clang.cmd' },
    @{ Abi = 'x86_64'; GoArch = 'amd64'; Clang = 'x86_64-linux-android21-clang.cmd' }
  )
}

# The ABIs to build: a comma-separated list (e.g. ZEN_ANDROID_ABIS from
# Gradle), all of them when empty. Unknown names are an error.
function Select-ZenAndroidAbis {
  param([string]$List)
  $all = Get-ZenAndroidAbis
  if (-not $List) {
    return $all
  }
  $wanted = @($List.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $selected = @()
  foreach ($name in $wanted) {
    $abi = $all | Where-Object { $_.Abi -eq $name }
    if (-not $abi) {
      throw "Unknown Android ABI '$name' (known: $(($all | ForEach-Object { $_.Abi }) -join ', '))"
    }
    $selected += $abi
  }
  return $selected
}
