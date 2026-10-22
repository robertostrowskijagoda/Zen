# Copies the Visual C++ runtime (msvcp140*.dll, vcruntime140*.dll) of the
# installed Visual Studio next to zen.exe, so the Windows zip runs on a
# computer without the VC++ Redistributable (Flutter's "Building your own
# zip file for Windows"). Used by .github/workflows/release.yml; works on a
# developer machine with Visual Studio too:
#
#   pwsh tool/ci/copy_vc_runtime.ps1 -Arch x64|arm64 -Destination build/windows/x64/runner/Release
#
# The files come from <VS>\VC\Redist\MSVC\<newest version>\<arch>\
# Microsoft.VC14x.CRT\ (the redistributable folder Microsoft's licence lets
# applications ship). tool/ci/check_windows_bundle.py then checks that
# every runtime library the binaries import is in the folder.
# ASCII only: Windows PowerShell 5.1 reads scripts without a BOM as ANSI.
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'arm64')]
  [string]$Arch,
  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
  throw "No folder $Destination (build the app first)"
}

$roots = @()
if (${env:ProgramFiles(x86)}) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $roots += @(& $vswhere -all -products * -property installationPath)
  }
}
if ($env:VCToolsRedistDir) {
  # A Developer Command Prompt names the folder itself.
  $roots += (Resolve-Path (Join-Path $env:VCToolsRedistDir '..\..\..\..')).Path
}

# The newest MSVC redistributable version folder (14.44.35112, ...) that
# has this architecture's CRT.
$best = $null
foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
  $redist = Join-Path $root 'VC\Redist\MSVC'
  if (-not (Test-Path -LiteralPath $redist)) {
    continue
  }
  foreach ($dir in Get-ChildItem -LiteralPath $redist -Directory) {
    $version = $null
    if (-not [version]::TryParse($dir.Name, [ref]$version)) {
      continue
    }
    $crt = Get-ChildItem -LiteralPath (Join-Path $dir.FullName $Arch) -Directory -Filter 'Microsoft.VC14*.CRT' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($crt -and (Test-Path -LiteralPath (Join-Path $crt.FullName 'msvcp140.dll')) -and
        (-not $best -or $version -gt $best.Version)) {
      $best = @{ Version = $version; Crt = $crt.FullName }
    }
  }
}
if (-not $best) {
  throw "No Visual C++ redistributable for $Arch found (Visual Studio with the C++ workload)"
}

$files = Get-ChildItem -LiteralPath $best.Crt -File |
  Where-Object { $_.Name -match '^(msvcp140(_\w+)?|vcruntime140(_\w+)?)\.dll$' }
if (-not $files) {
  throw "No runtime libraries in $($best.Crt)"
}
foreach ($file in $files) {
  Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
}
Write-Host "Visual C++ runtime $($best.Version) ($Arch): $(($files | ForEach-Object Name) -join ', ')"
