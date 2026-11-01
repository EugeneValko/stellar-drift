# Resolves $Godot (Godot 4.7.2 executable) for Windows helper scripts.
$Godot = $env:GODOT
$cfg = Join-Path $PSScriptRoot ".godot_path.txt"
if (-not $Godot -and (Test-Path $cfg)) { $Godot = (Get-Content $cfg -Raw).Trim() }
if (-not $Godot) { $c = Get-Command godot -ErrorAction SilentlyContinue; if ($c) { $Godot = $c.Source } }
if (-not $Godot -or -not (Test-Path $Godot)) { throw "Godot 4.7.2 not found: set `$env:GODOT or write its path into tools/.godot_path.txt (see docs/LOCAL_RENDER.md)" }
