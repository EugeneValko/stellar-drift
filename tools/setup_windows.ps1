# One-time setup on Windows: Godot (version from tools/versions.env) + export templates.
#   powershell -ExecutionPolicy Bypass -File tools/setup_windows.ps1 [-Dest C:\Tools\Godot]
# Writes the console exe path into tools/.godot_path.txt (gitignored), used by all tools/*.ps1.
# Optional extras (install yourself): Blender 5.2 (regenerate ship/flora models), ffmpeg (videos), Python 3 + numpy (tools/textures, sky_sim).
param([string]$Dest = "C:\Tools\Godot")
$ErrorActionPreference = "Stop"
$envFile = Get-Content (Join-Path $PSScriptRoot "versions.env")
$v = (($envFile | Where-Object { $_ -match '^GODOT_VERSION=' }) -replace 'GODOT_VERSION=', '').Trim()
$r = (($envFile | Where-Object { $_ -match '^GODOT_RELEASE=' }) -replace 'GODOT_RELEASE=', '').Trim()
$gv = "$v-$r"
$base = "https://github.com/godotengine/godot/releases/download/$gv"
New-Item -ItemType Directory -Force $Dest | Out-Null
$exe = Join-Path $Dest "Godot_v${gv}_win64_console.exe"
if (-not (Test-Path $exe)) {
  Write-Host "[setup] downloading Godot $gv"
  $zip = Join-Path $env:TEMP "godot_$gv.zip"
  Invoke-WebRequest "$base/Godot_v${gv}_win64.exe.zip" -OutFile $zip
  Expand-Archive $zip -DestinationPath $Dest -Force
  Remove-Item $zip
}
Set-Content (Join-Path $PSScriptRoot ".godot_path.txt") $exe
$tpl = Join-Path $env:APPDATA "Godot\export_templates\$v.$r"
if (-not (Test-Path (Join-Path $tpl "windows_release_x86_64.exe"))) {
  Write-Host "[setup] downloading export templates (~1 GB)"
  $tpz = Join-Path $env:TEMP "godot_tpl_$gv.zip"
  Invoke-WebRequest "$base/Godot_v${gv}_export_templates.tpz" -OutFile $tpz
  $tmp = Join-Path $env:TEMP "godot_tpl_$gv"
  Expand-Archive $tpz -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force $tpl | Out-Null
  Move-Item (Join-Path $tmp "templates\*") $tpl -Force
  Remove-Item -Recurse $tmp, $tpz
}
& $exe --version
Write-Host "[setup] OK. Godot: $exe ; templates: $tpl"
