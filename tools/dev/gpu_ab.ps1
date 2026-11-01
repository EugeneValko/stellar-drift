# A/B matrix: every view x every variant, one gpu_bench run each, snapshots for visual diffs.
#   powershell -ExecutionPolicy Bypass -File tools/dev/gpu_ab.ps1 -Views "main:terra_low,atmo_test:ocean_glint" `
#       -Variants "base|--cu_cloud_skip_stride=1;skip|" -OutDir <dir> [-Warm 300] [-Frames 200]
# Variant = name|space-separated user args; variants separated by ';'. Snapshots: <OutDir>/<cam>-<name>.png
param([string]$Views, [string]$Variants, [string]$OutDir, [int]$Warm = 300, [int]$Frames = 200)
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "tools/godot_path.ps1")
New-Item -ItemType Directory -Force $OutDir | Out-Null
$out = [IO.Path]::GetFullPath($OutDir)
foreach ($v in $Views.Split(",")) {
  $scene, $cam = $v.Split(":")
  $path = if ($scene -eq "main") { "res://scenes/main.tscn" } else { "res://scenes/test/$scene.tscn" }
  foreach ($var in $Variants.Split(";")) {
    $name, $extra = $var.Split("|")
    $a = @("--path", $root, "--resolution", "1920x1080", "--fullscreen", "--disable-vsync", "-s", "res://tools/dev/gpu_bench.gd", "--",
           "--scene=$path", "--cam=$cam", "--warm=$Warm", "--frames=$Frames", "--label=${cam}:$name", "--snap=$out/$cam-$name.png")
    if ($extra) { $a += $extra.Trim().Split(" ") }
    & $Godot @a 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -cmatch '\[gpubench\]|SCRIPT ERROR' } | Select-Object -First 3
  }
}
