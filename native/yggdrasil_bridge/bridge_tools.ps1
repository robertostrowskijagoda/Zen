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
      $ndk = Get-ChildItem $ndkDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
      if ($ndk) {
        return $ndk
      }
    }
  }
  return $null
}

# C compiler for cgo on Windows: CC, gcc on PATH or Strawberry Perl's gcc.
function Find-ZenCCompiler {
  if ($env:CC) {
    return $env:CC
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
