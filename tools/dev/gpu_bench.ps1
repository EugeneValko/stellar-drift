# Runs tools/dev/gpu_bench.gd over a list of "scene:cam" views (vsync off, 1920x1080 fullscreen).
#   powershell -ExecutionPolicy Bypass -File tools/dev/gpu_bench.ps1 -Views "main:terra_low,atmo_test:ocean_glint" [-Warm 300] [-Frames 300] [-SnapDir dir] [-Extra "--quality=1"]
param([string]$Views, [int]$Warm = 300, [int]$Frames = 300, [string]$SnapDir = "", [string]$Extra = "")
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "tools/godot_path.ps1")
foreach ($v in $Views.Split(",")) {
  $scene, $cam = $v.Split(":")
  $path = if ($scene -eq "main") { "res://scenes/main.tscn" } else { "res://scenes/test/$scene.tscn" }
  $a = @("--path", $root, "--resolution", "1920x1080", "--fullscreen", "--disable-vsync", "-s", "res://tools/dev/gpu_bench.gd", "--",
         "--scene=$path", "--cam=$cam", "--warm=$Warm", "--frames=$Frames", "--label=${scene}:$cam")
  if ($SnapDir) {
    $dir = if ([IO.Path]::IsPathRooted($SnapDir)) { $SnapDir } else { Join-Path (Get-Location) $SnapDir }
    $a += "--snap=" + [IO.Path]::GetFullPath("$dir/${scene}_$cam.png")
  }
  if ($Extra) { $a += $Extra.Split(" ") }
  & $Godot @a 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -cmatch '\[gpubench\]|SCRIPT ERROR|^ERROR' } | Select-Object -First 6
}
