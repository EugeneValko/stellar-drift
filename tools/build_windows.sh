#!/usr/bin/env bash
# Export the Windows build locally (same as CI): build/windows/StellarDrift.exe (+ zip)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/windows
godot --headless --import >/dev/null 2>&1 || true
godot --headless --export-release "Windows Desktop" build/windows/StellarDrift.exe 2>&1 | grep -E 'ERROR|WARNING|savepack|export' || true
test -f build/windows/StellarDrift.exe
(cd build/windows && rm -f ../StellarDrift-windows.zip && zip -qr ../StellarDrift-windows.zip .)
ls -lh build/windows build/StellarDrift-windows.zip
