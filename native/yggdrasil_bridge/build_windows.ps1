$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $root 'bin'
$portableGo = Join-Path $env:LOCALAPPDATA 'Programs\GoPortable\Go\bin\go.exe'
$portableGcc = 'C:\Strawberry\c\bin\gcc.exe'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
  if (-not (Test-Path $portableGo)) {
    throw "Go executable not found on PATH or at $portableGo"
  }
  $env:PATH = "$(Split-Path $portableGo -Parent);$env:PATH"
  $env:GOROOT = Join-Path $env:LOCALAPPDATA 'Programs\GoPortable\Go'
}

if (-not $env:CC -and (Test-Path $portableGcc)) {
  $env:CC = $portableGcc
}

New-Item -ItemType Directory -Path $bin -Force | Out-Null
Push-Location $root
try {
  go build -trimpath -buildmode=c-shared -ldflags="-s -w" -o (Join-Path $bin 'yggdrasil_bridge.dll') .
  if ($LASTEXITCODE -ne 0) {
    throw 'go build failed'
  }
}
finally {
  Pop-Location
}
