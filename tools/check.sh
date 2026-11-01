#!/usr/bin/env bash
# Fast sanity check: import project and parse all scripts headless. Run before every commit.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=$(godot --headless --import 2>&1; timeout 120 godot --headless --quit-after 5 2>&1)
ERR=$(echo "$OUT" | grep -E 'SCRIPT ERROR|Parse Error|ERROR: ' | grep -vE 'ALSA|audio|init_output_device' || true)
if [ -n "$ERR" ]; then echo "$ERR"; echo "[check] FAILED"; exit 1; fi
echo "[check] OK"
