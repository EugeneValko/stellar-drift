# Runs a scene for N seconds on the real GPU and prints average/min FPS (scene must support --bench via Capture.args or just run).
#   powershell -ExecutionPolicy Bypass -File tools/fps_bench.ps1 scenes/main.tscn 20
param([string]$Scene = "scenes/main.tscn", [int]$Seconds = 20)
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
& $Godot --path $root --resolution 1920x1080 --fullscreen --print-fps --quit-after ($Seconds*60) $Scene 2>&1 | Where-Object { $_ -match "FPS|ERROR" } | Select-Object -Last 15
