# Windows: scripted end-to-end playtest (Terra -> Selene -> walk -> Aurelion warp -> Terra), must be 20/20 PASS.
#   powershell -ExecutionPolicy Bypass -File tools/playtest.ps1 [all|quick] [seed]
param([string]$Mode = "all", [int]$Seed = 7)
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null
& $Godot --headless --fixed-fps 60 --path $root -s tools/dev/playtest.gd -- $Mode "seed=$Seed" 2>&1 | Tee-Object -FilePath (Join-Path $root "build\playtest.log")
