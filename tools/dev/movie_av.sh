#!/usr/bin/env bash
# Like tools/movie.sh, but keeps the game audio: Godot's Movie Maker writes frameNNNNNNNN.png plus
# frame.wav (the mixed procedural audio); both are muxed into the mp4 (AAC 160k).
#   tools/dev/movie_av.sh <scene.tscn> <out.mp4> <seconds> [--key=value ...]
set -euo pipefail
cd "$(dirname "$0")/../.."
SCENE="$1"; OUT="$(realpath -m "$2")"; SECS="$3"; shift 3
FPS=${FPS:-30}; RES=${RES:-1280x720}
TMP=$(mktemp -d)
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
xvfb-run -a -s "-screen 0 ${RES}x24" godot --rendering-driver vulkan --path . \
  --write-movie "$TMP/frame.png" --fixed-fps "$FPS" --quit-after $((SECS*FPS)) \
  --resolution "$RES" "$SCENE" -- --res="$RES" "$@" 2>&1 | grep -E 'ERROR|SCRIPT|\[demo\]|\[audio\]' || true
mkdir -p "$(dirname "$OUT")"
if [ -f "$TMP/frame.wav" ]; then
  ffmpeg -y -loglevel error -framerate "$FPS" -i "$TMP/frame%08d.png" -i "$TMP/frame.wav" \
    -c:v libx264 -pix_fmt yuv420p -crf 20 -c:a aac -b:a 160k -shortest "$OUT"
  cp "$TMP/frame.wav" "${OUT%.mp4}.wav"
else
  ffmpeg -y -loglevel error -framerate "$FPS" -i "$TMP/frame%08d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 "$OUT"
fi
rm -rf "$TMP"; echo "[movie_av] $OUT"
