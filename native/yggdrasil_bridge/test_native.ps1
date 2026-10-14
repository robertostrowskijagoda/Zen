$ErrorActionPreference = 'Stop'

# Runs the Go bridge tests with the same portable Go the build scripts use.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
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
$env:CGO_ENABLED = '1'

Push-Location $root
try {
  # Resolves go.sum after a dependency bump (e.g. Yggdrasil).
  go mod tidy
  if ($LASTEXITCODE -ne 0) { throw 'go mod tidy failed' }
  go vet .
  go test -count=1 .
}
finally {
  Pop-Location
}
