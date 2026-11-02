# Windows movie capture (Godot Movie Maker, fixed fps) -> mp4 if ffmpeg is on PATH, else PNG frames.
#   powershell -ExecutionPolicy Bypass -File tools/movie.ps1 scenes/test/x.tscn out.mp4 6 [--cam=preset]
param([string]$Scene, [string]$Out, [int]$Seconds = 6, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
$fps = if ($env:FPS) { [int]$env:FPS } else { 30 }
$res = if ($env:RES) { $env:RES } else { "1920x1080" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sd_movie_" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$ErrorActionPreference = "Continue"   # Godot's exit warnings on stderr must not abort before ffmpeg
& $Godot --path $root --write-movie (Join-Path $tmp "frame.png") --fixed-fps $fps --quit-after ($Seconds*$fps) --resolution $res --fullscreen $Scene -- @Rest 2>&1 | Where-Object { $_ -match "ERROR|SCRIPT" }
$outFull = if ([IO.Path]::IsPathRooted($Out)) { [IO.Path]::GetFullPath($Out) } else { [IO.Path]::GetFullPath((Join-Path (Get-Location) $Out)) }
New-Item -ItemType Directory -Force (Split-Path $outFull) | Out-Null
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
  ffmpeg -y -loglevel error -framerate $fps -i (Join-Path $tmp "frame%08d.png") -c:v libx264 -pix_fmt yuv420p -crf 18 $outFull
  Remove-Item -Recurse $tmp; Write-Host "[movie] $outFull"
} else { Write-Host "[movie] ffmpeg not found; frames left in $tmp" }
