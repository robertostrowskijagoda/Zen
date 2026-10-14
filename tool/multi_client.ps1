# Uruchamia kilka instancji Zen na tym komputerze — każda to osobna osoba
# z własnymi danymi, kluczami i węzłem sieci (--zen-profile).
#
#   powershell -File tool\multi_client.ps1 -Count 4            # buduje i startuje 4
#   powershell -File tool\multi_client.ps1 -Count 4 -NoBuild   # bez budowania
#   powershell -File tool\multi_client.ps1 -Stop               # zamyka wszystkie
#   powershell -File tool\multi_client.ps1 -Phone              # + telefon przez adb
#
# Potem: dart run tool/zen_drive.dart find
#        dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891
param(
  [int]$Count = 3,
  [switch]$NoBuild,
  [switch]$Stop,
  [switch]$Phone,
  [string]$Prefix = 'sim',
  # Okna startują zminimalizowane (nie zasłaniają pracy); -Show pokazuje je.
  [switch]$Show
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = Join-Path $root 'build\windows\x64\runner\Debug\zen.exe'

if ($Stop) {
  Get-CimInstance Win32_Process -Filter "Name='zen.exe'" |
    Where-Object { $_.CommandLine -like '*--zen-profile=*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Zamknięto $($_.ProcessId)" }
  exit 0
}

if (-not $NoBuild -or -not (Test-Path $exe)) {
  Push-Location $root
  try { flutter build windows --debug } finally { Pop-Location }
}

for ($i = 1; $i -le $Count; $i++) {
  $name = "$Prefix$i"
  $style = if ($Show) { 'Normal' } else { 'Minimized' }
  Start-Process -FilePath $exe -ArgumentList "--zen-profile=$name" -WindowStyle $style | Out-Null
  Write-Host "Start: $name"
  # One by one, so the harness ports come in order (48888, 48889, …).
  Start-Sleep -Seconds 6
}

if ($Phone) {
  adb forward tcp:48900 tcp:48888 | Out-Null
  Write-Host 'Telefon: port 48900 (adb forward)'
}

Write-Host 'Gotowe. Sprawdź: dart run tool/zen_drive.dart find'
