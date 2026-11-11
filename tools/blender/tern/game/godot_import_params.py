"""Set Godot import parameters of the Tern textures: VRAM compression + mipmaps (normal maps as normal maps).

Godot's first headless import treats loose images as lossless 2D textures without mipmaps; the game needs
VRAM-compressed, mip-mapped textures. Run after the first `godot --headless --import`, then import again:
    python tools/blender/tern/game/godot_import_params.py
"""
import glob
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
SET = {"compress/mode": "2", "mipmaps/generate": "true", "detect_3d/compress_to": "0", "compress/high_quality": "false"}

for path in glob.glob(os.path.join(ROOT, "assets", "models", "tern", "*.webp.import")):
    txt = open(path, encoding="utf-8").read()
    want = dict(SET)
    want["compress/normal_map"] = "1" if "_normal." in path else "2"
    for k, v in want.items():
        txt = re.sub(r"(?m)^%s=.*$" % re.escape(k), "%s=%s" % (k, v), txt)
    open(path, "w", encoding="utf-8", newline="\n").write(txt)
    print("set", os.path.basename(path))
