#!/usr/bin/env bash
# Idempotent setup of the cloud dev container: Godot + export templates,
# software Vulkan (lavapipe), Xvfb, ffmpeg, Blender. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/versions.env"
GV="${GODOT_VERSION}-${GODOT_RELEASE}"
GH="https://github.com/godotengine/godot/releases/download/${GV}"

if ! command -v godot >/dev/null || ! godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}"; then
  echo "[setup] Godot ${GV}"
  mkdir -p /opt/godot && cd /opt/godot
  curl -sSL -o godot.zip "${GH}/Godot_v${GV}_linux.x86_64.zip" && unzip -oq godot.zip && rm godot.zip
  ln -sf "/opt/godot/Godot_v${GV}_linux.x86_64" /usr/local/bin/godot
fi

TPL="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}"
if [ ! -f "$TPL/windows_release_x86_64.exe" ]; then
  echo "[setup] export templates"
  mkdir -p "$TPL" && cd /tmp
  curl -sSL -o tpl.tpz "${GH}/Godot_v${GV}_export_templates.tpz"
  rm -rf tpl && unzip -oq tpl.tpz -d tpl && mv tpl/templates/* "$TPL/" && rm -rf tpl tpl.tpz
fi

if [ ! -f /usr/share/vulkan/icd.d/lvp_icd.json ] || ! command -v xvfb-run >/dev/null || ! command -v ffmpeg >/dev/null; then
  echo "[setup] apt: mesa-vulkan-drivers xvfb ffmpeg"
  apt-get update -qq && apt-get install -y -qq mesa-vulkan-drivers vulkan-tools xvfb ffmpeg >/dev/null
fi

if ! command -v blender >/dev/null; then
  echo "[setup] Blender ${BLENDER_VERSION}"
  mkdir -p /opt/blender && cd /opt/blender
  curl -sSL -o b.tar.xz "https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz"
  tar xf b.tar.xz && rm b.tar.xz
  ln -sf "/opt/blender/blender-${BLENDER_VERSION}-linux-x64/blender" /usr/local/bin/blender
fi

echo "[setup] OK: $(godot --version) | $(blender -b --version 2>/dev/null | head -1)"
