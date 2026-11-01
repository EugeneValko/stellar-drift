# Windows (real GPU) screenshot helper — same interface as tools/shot.sh.
#   powershell -ExecutionPolicy Bypass -File tools/shot.ps1 scenes/test/x.tscn out.png [--cam=preset] [--key=val]
#   powershell -ExecutionPolicy Bypass -File tools/shot.ps1 scenes/test/x.tscn --shots=a,b --outdir=docs/screenshots/x
# Godot binary: $env:GODOT or tools/.godot_path.txt or `godot` on PATH.
param([Parameter(Mandatory=$true)][string]$Scene, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
$args2 = @()
foreach ($a in $Rest) {
  if (-not $a.StartsWith("--")) { $args2 += "--shot=" + [IO.Path]::GetFullPath((Join-Path (Get-Location) $a)) }
  elseif ($a.StartsWith("--outdir=")) { $args2 += "--outdir=" + [IO.Path]::GetFullPath((Join-Path (Get-Location) $a.Substring(9))) }
  else { $args2 += $a }
}
if (-not (Test-Path (Join-Path $root ".godot"))) { & $Godot --headless --path $root --import | Out-Null }
# --fullscreen: on a 1920x1080 monitor a windowed 1080p window gets shrunk by the taskbar
& $Godot --path $root --resolution 1920x1080 --fullscreen $Scene -- @args2 2>&1 | Where-Object { $_ -match "capture|ERROR|SCRIPT" }
