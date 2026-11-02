# Windows: export the release build locally -> build/windows/StellarDrift.exe (+ zip). Needs tools/setup_windows.ps1 once.
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
$out = Join-Path $root "build\windows"
New-Item -ItemType Directory -Force $out | Out-Null
& $Godot --headless --path $root --import | Out-Null
& $Godot --headless --path $root --export-release "Windows Desktop" (Join-Path $out "StellarDrift.exe")
if (-not (Test-Path (Join-Path $out "StellarDrift.exe"))) { Write-Host "[build] FAILED"; exit 1 }
Compress-Archive -Force -Path (Join-Path $out "*") -DestinationPath (Join-Path $root "build\StellarDrift-windows.zip")
Get-ChildItem (Join-Path $root "build") -Recurse -File | Select-Object FullName, Length
