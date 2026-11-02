# Windows: import project + parse/run all scripts headless for a few frames. Run before every commit.
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "godot_path.ps1")
$out = (& $Godot --headless --path $root --import 2>&1) + (& $Godot --headless --path $root --quit-after 5 2>&1)
$err = $out | Where-Object { $_ -match 'SCRIPT ERROR|Parse Error|ERROR: ' -and $_ -notmatch 'audio|WASAPI' }
if ($err) { $err; Write-Host "[check] FAILED"; exit 1 } else { Write-Host "[check] OK" }
