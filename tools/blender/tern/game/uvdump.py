"""Debug: draw the UV layout of objects in a saved work .blend into PNGs.

    blender -b build/tern/game/tern_game_work.blend -P tools/blender/tern/game/uvdump.py -- REF_A,REF_B,low_*
"""
import fnmatch
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

import bpy  # noqa: E402
import numpy as np  # noqa: E402

import bake as BK  # noqa: E402


def draw(objs, path, size=1024):
    img = np.zeros((size, size, 3), dtype=np.float32)
    for k, ob in enumerate(objs):
        me = ob.data
        if not me.uv_layers:
            continue
        uv = np.empty(len(me.loops) * 2, dtype=np.float32)
        me.uv_layers.active.data.foreach_get("uv", uv)
        uv = uv.reshape(-1, 2)
        col = np.array([(0.3 + 0.7 * ((k * 37) % 7) / 6), (0.3 + 0.7 * ((k * 53) % 5) / 4), 1.0 - 0.6 * ((k * 17) % 3) / 2])
        for p in me.polygons:
            idx = list(p.loop_indices)
            for a, b in zip(idx, idx[1:] + idx[:1]):
                p0, p1 = uv[a] * (size - 1), uv[b] * (size - 1)
                n = int(max(abs(p1 - p0).max(), 1)) + 1
                t = np.linspace(0, 1, n)[:, None]
                q = (p0 + (p1 - p0) * t).astype(int)
                ok = (q[:, 0] >= 0) & (q[:, 0] < size) & (q[:, 1] >= 0) & (q[:, 1] < size)
                q = q[ok]
                img[q[:, 1], q[:, 0]] = col
    BK.write_png(path, img)
    print("UVDUMP", path)


pats = (sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "REF_*").split(",")
objs = [o for o in bpy.data.objects if o.type == "MESH" and any(fnmatch.fnmatch(o.name, p) for p in pats)]
print("objects", [o.name for o in objs])
groups = {}
for o in objs:
    groups.setdefault(o.name.split("_")[0] + ("_" + o.name.split("_")[1] if o.name.startswith("REF") else ""), []).append(o)
for g, os_ in groups.items():
    draw(os_, os.path.join(C.BUILD, "uv_%s.png" % g))
