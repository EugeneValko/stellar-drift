#!/usr/bin/env bash
# Record a short deterministic clip with Godot's Movie Maker (fixed fps, not realtime),
# then convert to mp4.  tools/movie.sh <scene.tscn> <out.mp4> <seconds> [--key=value ...]
set -euo pipefail
cd "$(dirname "$0")/.."
SCENE="$1"; OUT="$(realpath -m "$2")"; SECS="$3"; shift 3
FPS=${FPS:-30}; RES=${RES:-1280x720}
TMP=$(mktemp -d)
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
xvfb-run -a -s "-screen 0 ${RES}x24" godot --rendering-driver vulkan --path . \
  --write-movie "$TMP/frame.png" --fixed-fps "$FPS" --quit-after $((SECS*FPS)) \
  --resolution "$RES" "$SCENE" -- "$@" 2>&1 | grep -E 'ERROR|SCRIPT' || true
mkdir -p "$(dirname "$OUT")"
ffmpeg -y -loglevel error -framerate "$FPS" -i "$TMP/frame%08d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 "$OUT"
rm -rf "$TMP"; echo "[movie] $OUT"
