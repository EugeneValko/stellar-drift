#!/usr/bin/env bash
# Render screenshot(s) offscreen with real Forward+ Vulkan (CPU lavapipe under Xvfb).
#   tools/shot.sh <scene.tscn> <out.png> [extra --key=value ...]
#   tools/shot.sh <scene.tscn> --shots=orbit,surface --outdir=docs/screenshots/x [...]
# ~20-40 s per launch at 1080p; prefer --shots for several angles in one launch.
set -euo pipefail
cd "$(dirname "$0")/.."
SCENE="$1"; shift
ARGS=()
if [[ "${1:-}" != --* ]]; then ARGS+=("--shot=$(realpath -m "$1")"); shift; fi
for a in "$@"; do
  if [[ "$a" == --outdir=* ]]; then a="--outdir=$(realpath -m "${a#--outdir=}")"; fi
  ARGS+=("$a")
done
[ -d .godot ] || godot --headless --import >/dev/null 2>&1 || true
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
RES=1920x1080; for a in "${ARGS[@]}"; do [[ "$a" == --res=* ]] && RES="${a#--res=}"; done
timeout "${SHOT_TIMEOUT:-600}" xvfb-run -a -s "-screen 0 ${RES}x24" \
  godot --rendering-driver vulkan --path . "$SCENE" -- "${ARGS[@]}" 2>&1 \
  | grep -vE 'ALSA|audio|snd_|init_output_device|^\s*at: |^\s*$' || true
