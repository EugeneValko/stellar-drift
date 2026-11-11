"""Preview one part module in the standard studio.

    blender -b --factory-startup -P tools/blender/tern/part_preview.py -- <module> [options]

<module> is a file in tools/blender/tern/parts/ (without .py) exposing `demo()` which builds the part(s)
into the current scene (around the origin) and returns nothing or a list of objects to frame.

Options: --views=front34,rear34,side,top  --res=960x540  --samples=64  --clay  --lens=70  --cols=2
         --out=<dir> (default build/tern/parts/<module>)  --blend (also save scene.blend)  --margin=1.1
"""
import importlib
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path[:0] = [HERE, os.path.join(HERE, "parts")]

import kit      # noqa: E402
import studio   # noqa: E402


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    name = argv[0]
    opt = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv[1:] if a.startswith("--"))
    res = tuple(int(v) for v in opt.get("res", "960x540").split("x"))
    out = os.path.abspath(opt.get("out", os.path.join(ROOT, "build", "tern", "parts", name)))
    studio.reset()
    studio.setup_cycles(res=res, samples=int(opt.get("samples", 64)))
    mod = importlib.import_module(name)
    objs = getattr(mod, opt.get("func", "demo"))()
    if not objs:
        objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    lo, hi = kit.bbox_world(objs)
    studio.world()
    studio.studio_rig(lo, hi)
    if "clay" in opt:
        studio.clay_override(True)
    views = opt.get("views", "front34,rear34,side,top").split(",")
    studio.render_views(out, lo, hi, views, lens=float(opt.get("lens", 70)), margin=float(opt.get("margin", 1.1)),
                        cols=int(opt.get("cols", 2)))
    if "blend" in opt:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "scene.blend"))
    print("PREVIEW_DONE", out, "size", tuple(round(v, 3) for v in (hi - lo)))


main()
