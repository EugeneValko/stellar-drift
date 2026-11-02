# Windows (real GPU) screenshot helper — same interface as tools/shot.sh.
#   powershell -ExecutionPolicy Bypass -File tools/shot.ps1 scenes/test/x.tscn out.png [--cam=preset] [--key=val]
#   powershell -ExecutionPolicy Bypass -File tools/shot.ps1 scenes/test/x.tscn --shots=a,b --outdir=docs/screenshots/x
# The game window opens outside the desktop (Capture --offscreen) so it never covers other windows;
# -Front: old fullscreen window (only when a check really needs it).
# Godot binary: $env:GODOT or tools/.godot_path.txt or `godot` on PATH.
param([Parameter(Mandatory=$true)][string]$Scene, [switch]$Front, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
function Abs([string]$p) { if ([IO.Path]::IsPathRooted($p)) { [IO.Path]::GetFullPath($p) } else { [IO.Path]::GetFullPath((Join-Path (Get-Location) $p)) } }
$args2 = @()
foreach ($a in $Rest) {
  if (-not $a.StartsWith("--")) { $args2 += "--shot=" + (Abs $a) }
  elseif ($a.StartsWith("--outdir=")) { $args2 += "--outdir=" + (Abs $a.Substring(9)) }
  else { $args2 += $a }
}
& $Godot --headless --path $root --import | Out-Null  # always: cheap when nothing changed
# windowed 1080p would be shrunk by the taskbar: fullscreen (-Front) or a borderless off-desktop window
$win = if ($Front) { @("--fullscreen") } else { @("--windowed", "--position", "-4000,0"); $args2 += "--offscreen" }
& $Godot --path $root --fixed-fps 60 --resolution 1920x1080 @win $Scene -- @args2 2>&1 | Where-Object { $_ -match "capture|ERROR|SCRIPT" }
